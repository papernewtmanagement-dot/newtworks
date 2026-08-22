-- ============================================================
-- TRIVIA — the generic room spine
--
-- One table, quiz_rooms, that ANY mode can sit on. A room is a
-- lobby of signed-in teammates who then play the same drawn
-- questions at the same time on their own devices, each scored
-- individually through their own quiz_attempts row - so every
-- existing scoring path (quiz_submit_answer, quiz_finish_attempt,
-- the weekly standings) keeps working untouched.
--
-- WHY ONE TABLE: mode-specific shared state lives in the `state`
-- jsonb. The spine owns the envelope (who is here, what mode,
-- what status, whose attempt is whose); each mode owns the shape
-- inside `state`. Same split that already works for
-- quiz_grid_sessions.
--
-- RLS ON, ZERO POLICIES, deliberately. Every read and write goes
-- through a SECURITY DEFINER function, same house convention as
-- quiz_night_sessions and quiz_grid_sessions. Nothing here is
-- readable straight from the browser.
--
-- LIVE UPDATES are browser-sent nudges plus the 10s fallback
-- poll. There is no database-side broadcast on this project and
-- there cannot be - realtime.messages has zero partitions and
-- writes to it fail silently. Do not add a trigger here.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.quiz_rooms (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL,
  mode_key              text NOT NULL,
  host_team_member_id   uuid NOT NULL,
  status                text NOT NULL DEFAULT 'lobby',
  -- [{team_member_id, attempt_id}] - names and scores are resolved on read,
  -- never stored, so a room can never disagree with the attempt rows.
  players               jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- frozen at open: question_count, seconds_per_question, whatever the mode needs
  config                jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- mode-owned shared state: the drawn item_ids, the board, the wheel, an index
  state                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at            timestamptz,
  finished_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.quiz_rooms
  ADD COLUMN IF NOT EXISTS state jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$ BEGIN
  ALTER TABLE public.quiz_rooms
    ADD CONSTRAINT quiz_rooms_status_check
    CHECK (status IN ('lobby','playing','finished','abandoned'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS ix_quiz_rooms_agency_status
  ON public.quiz_rooms (agency_id, status, created_at DESC);

-- One open room per host at a time. Stops orphan lobbies piling up when
-- somebody opens a room, wanders off, and opens another one tomorrow.
CREATE UNIQUE INDEX IF NOT EXISTS uq_quiz_rooms_one_open_per_host
  ON public.quiz_rooms (host_team_member_id)
  WHERE status IN ('lobby','playing');

ALTER TABLE public.quiz_rooms ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- INTERNAL HELPERS — no grants at all. Callable only from the
-- other functions in this file and from the per-mode start
-- functions that will sit on top of this spine, all of which run
-- as owner. Never exposed over the API.
-- ============================================================

-- Locks the room and returns it, checking agency and (optionally) that the
-- caller is the host. Every write path starts here so the checks cannot drift.
CREATE OR REPLACE FUNCTION public._quiz_room_locked(
  p_room_id uuid,
  p_require_host boolean DEFAULT false
) RETURNS public.quiz_rooms
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_room public.quiz_rooms;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_room FROM public.quiz_rooms
   WHERE id = p_room_id AND agency_id = v_agency FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'that room was not found'; END IF;

  IF p_require_host AND v_room.host_team_member_id <> v_member THEN
    RAISE EXCEPTION 'only the host can do that';
  END IF;
  RETURN v_room;
END; $$;

-- Merges a patch into the room's mode-owned state. Shallow merge on purpose:
-- a mode that needs to replace a nested object passes the whole object.
CREATE OR REPLACE FUNCTION public._quiz_room_patch_state(
  p_room_id uuid,
  p_patch jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_state jsonb;
BEGIN
  UPDATE public.quiz_rooms
     SET state = COALESCE(state, '{}'::jsonb) || COALESCE(p_patch, '{}'::jsonb),
         updated_at = now()
   WHERE id = p_room_id
  RETURNING state INTO v_state;
  IF NOT FOUND THEN RAISE EXCEPTION 'that room was not found'; END IF;
  RETURN v_state;
END; $$;

-- THE EXTENSION POINT. A per-mode start function draws its own questions,
-- then calls this to flip the room into play and open one attempt per player.
-- p_attempt_context is merged into every player's quiz_attempts.context, so
-- the existing per-player play functions read the room's draw exactly the way
-- they read a solo draw.
CREATE OR REPLACE FUNCTION public._quiz_room_begin(
  p_room_id uuid,
  p_state jsonb DEFAULT '{}'::jsonb,
  p_attempt_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_room public.quiz_rooms; v_players jsonb := '[]'::jsonb;
  v_entry jsonb; v_member uuid; v_attempt uuid;
BEGIN
  SELECT * INTO v_room FROM public.quiz_rooms WHERE id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'that room was not found'; END IF;
  IF v_room.status <> 'lobby' THEN RAISE EXCEPTION 'this room has already started'; END IF;
  IF jsonb_array_length(COALESCE(v_room.players, '[]'::jsonb)) < 1 THEN
    RAISE EXCEPTION 'nobody has joined yet';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(v_room.players) LOOP
    v_member := (v_entry->>'team_member_id')::uuid;
    INSERT INTO public.quiz_attempts (agency_id, team_member_id, mode_key, context)
    VALUES (v_room.agency_id, v_member, v_room.mode_key,
            COALESCE(p_attempt_context, '{}'::jsonb)
              || jsonb_build_object('room_id', p_room_id))
    RETURNING id INTO v_attempt;
    v_players := v_players || jsonb_build_array(jsonb_build_object(
      'team_member_id', v_member, 'attempt_id', v_attempt));
  END LOOP;

  UPDATE public.quiz_rooms
     SET players = v_players,
         state = COALESCE(state, '{}'::jsonb) || COALESCE(p_state, '{}'::jsonb),
         status = 'playing', started_at = now(), updated_at = now()
   WHERE id = p_room_id;

  RETURN public.quiz_room_state(p_room_id);
END; $$;

-- ============================================================
-- THE PUBLIC SPINE
-- ============================================================

-- Everything anyone needs to draw a room: who is here, what they have scored
-- so far, and the mode's own shared state. Scores are computed from the
-- answer rows every time - the room never stores a score of its own, so a
-- client can never report one.
CREATE OR REPLACE FUNCTION public.quiz_room_state(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid; v_member uuid; v_room public.quiz_rooms;
  v_players jsonb; v_my_attempt uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_room FROM public.quiz_rooms
   WHERE id = p_room_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that room was not found'; END IF;

  SELECT jsonb_agg(y.x ORDER BY (y.x->>'points')::int DESC NULLS LAST, y.x->>'name')
    INTO v_players
    FROM (
      SELECT jsonb_build_object(
        'team_member_id', pm.member_id,
        'name', COALESCE(NULLIF(t.nickname,''), t.first_name, '—'),
        'is_me', (pm.member_id = v_member),
        'is_host', (pm.member_id = v_room.host_team_member_id),
        'attempt_id', pm.attempt_id,
        'finished', (a.finished_at IS NOT NULL),
        'answered_count', COALESCE((SELECT COUNT(*) FROM public.quiz_answers qa
                                     WHERE qa.attempt_id = pm.attempt_id), 0),
        'correct_count', COALESCE((SELECT COUNT(*) FROM public.quiz_answers qa
                                    WHERE qa.attempt_id = pm.attempt_id
                                      AND qa.was_correct), 0),
        'points', COALESCE((SELECT SUM(qa.points) FROM public.quiz_answers qa
                             WHERE qa.attempt_id = pm.attempt_id), 0)
      ) AS x
        FROM (SELECT (e->>'team_member_id')::uuid AS member_id,
                     NULLIF(e->>'attempt_id','')::uuid AS attempt_id
                FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e) pm
        LEFT JOIN public.team t ON t.id = pm.member_id
        LEFT JOIN public.quiz_attempts a ON a.id = pm.attempt_id
    ) y;

  SELECT NULLIF(e->>'attempt_id','')::uuid INTO v_my_attempt
    FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
   WHERE (e->>'team_member_id')::uuid = v_member
   LIMIT 1;

  RETURN jsonb_build_object(
    'room_id', v_room.id,
    'mode_key', v_room.mode_key,
    'status', v_room.status,
    'is_host', (v_room.host_team_member_id = v_member),
    'is_in', EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
                      WHERE (e->>'team_member_id')::uuid = v_member),
    'my_attempt_id', v_my_attempt,
    'player_count', jsonb_array_length(COALESCE(v_room.players,'[]'::jsonb)),
    'players', COALESCE(v_players, '[]'::jsonb),
    'config', COALESCE(v_room.config, '{}'::jsonb),
    'state', COALESCE(v_room.state, '{}'::jsonb),
    'started_at', v_room.started_at,
    'finished_at', v_room.finished_at,
    'updated_at', v_room.updated_at);
END; $$;

-- Opens a lobby for one mode. The host is in it from the moment it exists -
-- a room with nobody in it is just litter.
CREATE OR REPLACE FUNCTION public.quiz_room_open(
  p_mode_key text,
  p_config jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_ok boolean; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT true INTO v_ok FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = p_mode_key AND is_active = true;
  IF v_ok IS NOT TRUE THEN RAISE EXCEPTION 'that game is not set up'; END IF;

  IF EXISTS (SELECT 1 FROM public.quiz_rooms
              WHERE host_team_member_id = v_member AND status IN ('lobby','playing')) THEN
    RAISE EXCEPTION 'you already have a room open - finish or close it first';
  END IF;

  INSERT INTO public.quiz_rooms (agency_id, mode_key, host_team_member_id, config, players)
  VALUES (v_agency, p_mode_key, v_member, COALESCE(p_config,'{}'::jsonb),
          jsonb_build_array(jsonb_build_object('team_member_id', v_member)))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

-- Every room in the agency that is still worth walking into. This is how a
-- teammate finds a room without anyone reading anyone a code.
CREATE OR REPLACE FUNCTION public.quiz_room_list_open(p_mode_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_rows jsonb;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'room_id', r.id,
        'mode_key', r.mode_key,
        'mode_title', m.title,
        'status', r.status,
        'host_name', COALESCE(NULLIF(t.nickname,''), t.first_name, '—'),
        'is_host', (r.host_team_member_id = v_member),
        'is_in', EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(r.players,'[]'::jsonb)) e
                          WHERE (e->>'team_member_id')::uuid = v_member),
        'player_count', jsonb_array_length(COALESCE(r.players,'[]'::jsonb)),
        'created_at', r.created_at) AS x
        FROM public.quiz_rooms r
        LEFT JOIN public.team t ON t.id = r.host_team_member_id
        LEFT JOIN public.quiz_modes m
               ON m.agency_id = r.agency_id AND m.mode_key = r.mode_key
       WHERE r.agency_id = v_agency
         AND r.status IN ('lobby','playing')
         AND (p_mode_key IS NULL OR r.mode_key = p_mode_key)
    ) z;
  RETURN COALESCE(v_rows, '[]'::jsonb);
END; $$;

-- Joining is lobby-only. Once the questions are drawn the field is fixed, or
-- a latecomer would be scored against a game they only saw half of.
CREATE OR REPLACE FUNCTION public.quiz_room_join(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_room public.quiz_rooms; v_member uuid;
BEGIN
  v_member := public.current_team_member_id();
  v_room := public._quiz_room_locked(p_room_id, false);
  IF v_room.status <> 'lobby' THEN RAISE EXCEPTION 'this game has already started'; END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
                  WHERE (e->>'team_member_id')::uuid = v_member) THEN
    UPDATE public.quiz_rooms
       SET players = COALESCE(players,'[]'::jsonb)
                     || jsonb_build_array(jsonb_build_object('team_member_id', v_member)),
           updated_at = now()
     WHERE id = p_room_id;
  END IF;
  RETURN public.quiz_room_state(p_room_id);
END; $$;

-- Leaving the lobby takes you off the list. If the host leaves, the room goes
-- with them - somebody has to own it and nobody else volunteered.
CREATE OR REPLACE FUNCTION public.quiz_room_leave(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_room public.quiz_rooms; v_member uuid; v_left jsonb;
BEGIN
  v_member := public.current_team_member_id();
  v_room := public._quiz_room_locked(p_room_id, false);

  IF v_room.host_team_member_id = v_member THEN
    UPDATE public.quiz_rooms
       SET status = 'abandoned', finished_at = now(), updated_at = now()
     WHERE id = p_room_id AND status IN ('lobby','playing');
    RETURN public.quiz_room_state(p_room_id);
  END IF;

  IF v_room.status <> 'lobby' THEN RAISE EXCEPTION 'the game has started - play it out'; END IF;

  SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_left
    FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
   WHERE (e->>'team_member_id')::uuid <> v_member;

  UPDATE public.quiz_rooms SET players = v_left, updated_at = now() WHERE id = p_room_id;
  RETURN public.quiz_room_state(p_room_id);
END; $$;

-- Host closes the room. Any attempt still open is finished on the way out, so
-- nobody is left with a half-scored game hanging on their record.
CREATE OR REPLACE FUNCTION public.quiz_room_abandon(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_room public.quiz_rooms; v_entry jsonb; v_attempt uuid;
BEGIN
  v_room := public._quiz_room_locked(p_room_id, true);
  IF v_room.status IN ('finished','abandoned') THEN
    RETURN public.quiz_room_state(p_room_id);
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) LOOP
    v_attempt := NULLIF(v_entry->>'attempt_id','')::uuid;
    IF v_attempt IS NOT NULL THEN
      UPDATE public.quiz_attempts SET finished_at = now()
       WHERE id = v_attempt AND finished_at IS NULL;
    END IF;
  END LOOP;

  UPDATE public.quiz_rooms
     SET status = 'abandoned', finished_at = now(), updated_at = now()
   WHERE id = p_room_id;
  RETURN public.quiz_room_state(p_room_id);
END; $$;

-- Each player finishes their own game and banks their own points through the
-- ordinary scoring path. The room closes itself once the last one is in.
CREATE OR REPLACE FUNCTION public.quiz_room_my_finish(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_room public.quiz_rooms; v_member uuid; v_attempt uuid;
  v_result jsonb; v_open int;
BEGIN
  v_member := public.current_team_member_id();
  v_room := public._quiz_room_locked(p_room_id, false);

  SELECT NULLIF(e->>'attempt_id','')::uuid INTO v_attempt
    FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
   WHERE (e->>'team_member_id')::uuid = v_member
   LIMIT 1;
  IF v_attempt IS NULL THEN RAISE EXCEPTION 'you are not playing in this room'; END IF;

  IF (SELECT finished_at FROM public.quiz_attempts WHERE id = v_attempt) IS NULL THEN
    v_result := public.quiz_finish_attempt(v_attempt);
  END IF;

  SELECT COUNT(*) INTO v_open
    FROM jsonb_array_elements(COALESCE(v_room.players,'[]'::jsonb)) e
    JOIN public.quiz_attempts a ON a.id = NULLIF(e->>'attempt_id','')::uuid
   WHERE a.finished_at IS NULL;

  IF v_open = 0 THEN
    UPDATE public.quiz_rooms
       SET status = 'finished', finished_at = now(), updated_at = now()
     WHERE id = p_room_id AND status = 'playing';
  END IF;

  RETURN jsonb_build_object('result', v_result, 'room', public.quiz_room_state(p_room_id));
END; $$;

-- Somebody closing the tab and coming back should land in their own room
-- rather than staring at an empty lobby list.
CREATE OR REPLACE FUNCTION public.quiz_room_my_active(p_mode_key text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_id uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT r.id INTO v_id FROM public.quiz_rooms r
   WHERE r.agency_id = v_agency
     AND r.status IN ('lobby','playing')
     AND (p_mode_key IS NULL OR r.mode_key = p_mode_key)
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(r.players,'[]'::jsonb)) e
                  WHERE (e->>'team_member_id')::uuid = v_member)
   ORDER BY r.created_at DESC LIMIT 1;
  RETURN v_id;
END; $$;

-- ============================================================
-- GRANTS — internals stay unreachable, the spine is for
-- signed-in teammates only. Postgres grants EXECUTE to everyone
-- by default, so the revoke is the part that matters.
-- ============================================================

REVOKE ALL ON FUNCTION public._quiz_room_locked(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._quiz_room_patch_state(uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._quiz_room_begin(uuid, jsonb, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.quiz_room_state(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_open(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_list_open(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_join(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_leave(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_abandon(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_my_finish(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_room_my_active(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.quiz_room_state(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_open(text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_list_open(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_join(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_leave(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_abandon(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_my_finish(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_room_my_active(text) TO authenticated, service_role;
