-- Trivia Night: push changes to every screen instead of every screen asking
-- twice a second.
--
-- WHY NOT A CHANGE SUBSCRIPTION (do not spend a cycle trying it): Realtime
-- applies row-level rules to change subscriptions, and quiz_night_sessions and
-- quiz_night_players both have row-level security ON with ZERO policies -
-- deny-all by design, everything routed through functions. A change
-- subscription on either would deliver nothing at all. Broadcast is the path.
--
-- WHY THE MESSAGE CARRIES NO GAME CONTENT: a raw change row for
-- quiz_night_sessions would include item_ids, which is the full list of
-- questions still to come. So these are NUDGES, not data - each message says
-- only "something changed on this session". The screen then re-calls
-- quiz_night_state, which stays the single source of truth and already decides
-- what a given player is allowed to see (it nulls out which option is correct
-- until the host flips to reveal).
--
-- THREE THINGS FIRE A NUDGE, because all three move what is on screen:
--   the session itself   - host started, moved on, flipped to reveal, ended
--   the player list      - somebody joined or left
--   an answer landing    - the host's "3 of 5 answered" counter
-- Only the third needed a lookup, and it gets an index.

CREATE INDEX IF NOT EXISTS ix_quiz_night_players_attempt
  ON public.quiz_night_players (attempt_id);

-- Who is allowed to listen. The subscription check runs as the signed-in person,
-- and it cannot read quiz_night_sessions directly for the deny-all reason above,
-- so the check goes through a function that runs as the table owner.
CREATE OR REPLACE FUNCTION public.quiz_night_can_watch(p_session_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.quiz_night_sessions s
     WHERE s.id = p_session_id
       AND s.agency_id IN (SELECT u.agency_id FROM public.users u
                            WHERE u.auth_user_id = auth.uid()));
$$;

REVOKE ALL ON FUNCTION public.quiz_night_can_watch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_night_can_watch(uuid) TO authenticated, service_role;

-- realtime.messages is deny-all until something says otherwise, which is why a
-- private channel refuses every subscriber by default. This opens exactly one
-- shape of topic - quiz_night:<session id> - and only to somebody in the agency
-- that session belongs to.
DROP POLICY IF EXISTS quiz_night_broadcast_read ON realtime.messages;
CREATE POLICY quiz_night_broadcast_read ON realtime.messages
  FOR SELECT TO authenticated
  USING (
    topic ~ '^quiz_night:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.quiz_night_can_watch(substring(topic from 12)::uuid)
  );

-- One nudge sender. A broadcast that fails must never take a game write down
-- with it, so the failure is caught - but it is WARNED, not swallowed, so a
-- broken channel shows up in the logs instead of looking like a screen that
-- simply stopped updating.
CREATE OR REPLACE FUNCTION public.quiz_night_notify(p_session_id uuid, p_kind text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_session_id IS NULL THEN RETURN; END IF;
  PERFORM realtime.send(
    jsonb_build_object('kind', p_kind, 'session_id', p_session_id),
    'refresh',
    'quiz_night:' || p_session_id::text,
    true);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trivia night nudge failed for session % (%): %',
    p_session_id, p_kind, SQLERRM;
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_night_notify(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_night_notify(uuid, text) FROM authenticated;

CREATE OR REPLACE FUNCTION public.trg_quiz_night_sessions_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.quiz_night_notify(COALESCE(NEW.id, OLD.id), 'session');
  RETURN NULL;
END; $function$;

REVOKE ALL ON FUNCTION public.trg_quiz_night_sessions_broadcast() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_quiz_night_sessions_broadcast() FROM authenticated;

DROP TRIGGER IF EXISTS quiz_night_sessions_broadcast ON public.quiz_night_sessions;
CREATE TRIGGER quiz_night_sessions_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.quiz_night_sessions
  FOR EACH ROW EXECUTE FUNCTION public.trg_quiz_night_sessions_broadcast();

CREATE OR REPLACE FUNCTION public.trg_quiz_night_players_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.quiz_night_notify(COALESCE(NEW.session_id, OLD.session_id), 'players');
  RETURN NULL;
END; $function$;

REVOKE ALL ON FUNCTION public.trg_quiz_night_players_broadcast() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_quiz_night_players_broadcast() FROM authenticated;

DROP TRIGGER IF EXISTS quiz_night_players_broadcast ON public.quiz_night_players;
CREATE TRIGGER quiz_night_players_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.quiz_night_players
  FOR EACH ROW EXECUTE FUNCTION public.trg_quiz_night_players_broadcast();

-- Answers land in one table for every mode, so this looks up whether the answer
-- belongs to a live night game and stays silent for the five solo modes.
CREATE OR REPLACE FUNCTION public.trg_quiz_answers_night_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_sid uuid;
BEGIN
  SELECT p.session_id INTO v_sid
    FROM public.quiz_night_players p
   WHERE p.attempt_id = NEW.attempt_id
   LIMIT 1;
  IF v_sid IS NOT NULL THEN
    PERFORM public.quiz_night_notify(v_sid, 'answered');
  END IF;
  RETURN NULL;
END; $function$;

REVOKE ALL ON FUNCTION public.trg_quiz_answers_night_broadcast() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_quiz_answers_night_broadcast() FROM authenticated;

DROP TRIGGER IF EXISTS quiz_answers_night_broadcast ON public.quiz_answers;
CREATE TRIGGER quiz_answers_night_broadcast
  AFTER INSERT ON public.quiz_answers
  FOR EACH ROW EXECUTE FUNCTION public.trg_quiz_answers_night_broadcast();