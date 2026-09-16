-- Scavenger Hunt: six stops, each one a passage lifted out of a live manual
-- page. The player says which page it came from. No authored content — the
-- stops are generated from the manual itself, so the hunt stays current as the
-- manual changes, and a stop nobody can place is a signal the page is hard to
-- find.

CREATE TABLE IF NOT EXISTS public.quiz_hunt_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active',
  stops jsonb NOT NULL DEFAULT '[]'::jsonb,
  current_index int NOT NULL DEFAULT 0,
  score int NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.quiz_hunt_sessions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_quiz_hunt_sessions_member
  ON public.quiz_hunt_sessions (agency_id, team_member_id, status);

CREATE OR REPLACE FUNCTION public._quiz_hunt_snippet(p_content text, p_title text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public' AS $fn$
DECLARE v text; v_start int;
BEGIN
  v := COALESCE(p_content, '');
  v := regexp_replace(v, '<[^>]+>', ' ', 'g');
  v := regexp_replace(v, 'https?://\S+', ' ', 'g');
  v := regexp_replace(v, '[#*_>`|~-]+', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  IF COALESCE(p_title, '') <> '' THEN
    v := regexp_replace(v, '(?i)' || regexp_replace(p_title, '([\^$.|?*+()\[\]{}\\])', '\\\1', 'g'), '...', 'g');
  END IF;
  v := trim(v);
  v_start := greatest(1, (length(v) / 5)::int);
  RETURN trim(substr(v, v_start, 320));
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_snippet(text, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public._quiz_hunt_build_stops(p_agency uuid, p_count int)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE
  v_row record; v_stops jsonb := '[]'::jsonb; v_decoys text[]; v_opts text[];
  v_shuffled text[]; v_correct int; v_snip text;
BEGIN
  FOR v_row IN
    SELECT m.id, m.title, m.manual_type, m.confluence_page_id, m.content
      FROM public.manuals m
     WHERE m.agency_id = p_agency
       AND m.is_active
       AND m.manual_type IN ('handbook', 'processes', 'admin')
       AND COALESCE(m.title, '') <> ''
       AND length(COALESCE(m.content, '')) >= 500
     ORDER BY random()
     LIMIT p_count
  LOOP
    SELECT array_agg(t) INTO v_decoys FROM (
      SELECT m2.title AS t FROM public.manuals m2
       WHERE m2.agency_id = p_agency AND m2.is_active
         AND m2.manual_type = v_row.manual_type
         AND m2.id <> v_row.id
         AND COALESCE(m2.title, '') <> ''
         AND lower(m2.title) <> lower(v_row.title)
       ORDER BY random() LIMIT 3
    ) d;

    IF v_decoys IS NULL OR array_length(v_decoys, 1) < 3 THEN
      SELECT array_agg(t) INTO v_decoys FROM (
        SELECT m3.title AS t FROM public.manuals m3
         WHERE m3.agency_id = p_agency AND m3.is_active
           AND m3.manual_type IN ('handbook', 'processes', 'admin')
           AND m3.id <> v_row.id
           AND COALESCE(m3.title, '') <> ''
           AND lower(m3.title) <> lower(v_row.title)
         ORDER BY random() LIMIT 3
      ) d2;
    END IF;

    IF v_decoys IS NULL OR array_length(v_decoys, 1) < 3 THEN CONTINUE; END IF;

    v_snip := public._quiz_hunt_snippet(v_row.content, v_row.title);
    IF length(COALESCE(v_snip, '')) < 80 THEN CONTINUE; END IF;

    v_opts := ARRAY[v_row.title] || v_decoys;
    SELECT array_agg(o ORDER BY random()) INTO v_shuffled FROM unnest(v_opts) o;
    v_correct := array_position(v_shuffled, v_row.title) - 1;

    v_stops := v_stops || jsonb_build_array(jsonb_build_object(
      'manual_id', v_row.id,
      'manual_type', v_row.manual_type,
      'page_id', v_row.confluence_page_id,
      'snippet', v_snip,
      'options', to_jsonb(v_shuffled),
      'correct_index', v_correct,
      'answered', false,
      'chosen', NULL,
      'correct', NULL
    ));
  END LOOP;

  RETURN v_stops;
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_build_stops(uuid, int) FROM PUBLIC;

-- The answer key is stripped from every stop the player has not answered yet.
CREATE OR REPLACE FUNCTION public._quiz_hunt_state_row(p_sess public.quiz_hunt_sessions)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE v_out jsonb := '[]'::jsonb; v_stop jsonb;
BEGIN
  FOR v_stop IN SELECT value FROM jsonb_array_elements(p_sess.stops) LOOP
    IF COALESCE((v_stop ->> 'answered')::boolean, false) THEN
      v_out := v_out || jsonb_build_array(v_stop);
    ELSE
      v_out := v_out || jsonb_build_array(
        (v_stop - 'correct_index' - 'manual_id' - 'page_id' - 'manual_type'));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'id', p_sess.id,
    'status', p_sess.status,
    'stops', v_out,
    'stop_count', jsonb_array_length(p_sess.stops),
    'current_index', p_sess.current_index,
    'score', p_sess.score,
    'started_at', p_sess.started_at,
    'finished_at', p_sess.finished_at
  );
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_state_row(public.quiz_hunt_sessions) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.quiz_hunt_available()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_n int;
BEGIN
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_agency IS NULL THEN RETURN 0; END IF;
  SELECT count(*) INTO v_n FROM public.manuals m
   WHERE m.agency_id = v_agency AND m.is_active
     AND m.manual_type IN ('handbook', 'processes', 'admin')
     AND COALESCE(m.title, '') <> ''
     AND length(COALESCE(m.content, '')) >= 500;
  RETURN COALESCE(v_n, 0);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hunt_start()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_member uuid; v_stops jsonb; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  UPDATE public.quiz_hunt_sessions
     SET status = 'finished', finished_at = now(), updated_at = now()
   WHERE agency_id = v_agency AND team_member_id = v_member AND status = 'active';

  v_stops := public._quiz_hunt_build_stops(v_agency, 6);
  IF jsonb_array_length(v_stops) < 4 THEN
    RAISE EXCEPTION 'the manual does not have enough pages to build a hunt yet';
  END IF;

  INSERT INTO public.quiz_hunt_sessions (agency_id, team_member_id, stops)
  VALUES (v_agency, v_member, v_stops)
  RETURNING id INTO v_new;
  RETURN v_new;
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hunt_state(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_member uuid; v_sess public.quiz_hunt_sessions;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_sess FROM public.quiz_hunt_sessions
   WHERE id = p_session_id AND agency_id = v_agency AND team_member_id = v_member;
  IF NOT FOUND THEN RAISE EXCEPTION 'that hunt was not found'; END IF;
  RETURN public._quiz_hunt_state_row(v_sess);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hunt_answer(p_session_id uuid, p_stop_index int, p_option_index int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_hunt_sessions;
  v_stop jsonb; v_stops jsonb; v_right boolean; v_score int;
  v_total int; v_answered int; v_status text; v_next int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_hunt_sessions
   WHERE id = p_session_id AND agency_id = v_agency AND team_member_id = v_member;
  IF NOT FOUND THEN RAISE EXCEPTION 'that hunt was not found'; END IF;
  IF v_sess.status <> 'active' THEN RAISE EXCEPTION 'that hunt is already finished'; END IF;

  v_total := jsonb_array_length(v_sess.stops);
  IF p_stop_index < 0 OR p_stop_index >= v_total THEN RAISE EXCEPTION 'that stop is not on this hunt'; END IF;

  v_stop := v_sess.stops -> p_stop_index;
  IF COALESCE((v_stop ->> 'answered')::boolean, false) THEN
    RAISE EXCEPTION 'that stop has already been answered';
  END IF;
  IF p_option_index < 0 OR p_option_index >= jsonb_array_length(v_stop -> 'options') THEN
    RAISE EXCEPTION 'that is not one of the choices';
  END IF;

  v_right := p_option_index = (v_stop ->> 'correct_index')::int;
  v_stop := v_stop
            || jsonb_build_object('answered', true, 'chosen', p_option_index, 'correct', v_right);
  v_stops := jsonb_set(v_sess.stops, ARRAY[p_stop_index::text], v_stop);
  v_score := v_sess.score + CASE WHEN v_right THEN 10 ELSE 0 END;

  SELECT count(*) INTO v_answered FROM jsonb_array_elements(v_stops) e
   WHERE COALESCE((e ->> 'answered')::boolean, false);

  v_status := CASE WHEN v_answered >= v_total THEN 'finished' ELSE 'active' END;
  v_next := least(p_stop_index + 1, v_total - 1);

  UPDATE public.quiz_hunt_sessions
     SET stops = v_stops,
         score = v_score,
         current_index = v_next,
         status = v_status,
         finished_at = CASE WHEN v_status = 'finished' THEN now() ELSE NULL END,
         updated_at = now()
   WHERE id = p_session_id
   RETURNING * INTO v_sess;

  RETURN public._quiz_hunt_state_row(v_sess)
         || jsonb_build_object('was_correct', v_right, 'stop', v_stop);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hunt_my_active_session()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_member uuid; v_id uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT id INTO v_id FROM public.quiz_hunt_sessions
   WHERE agency_id = v_agency AND team_member_id = v_member AND status = 'active'
   ORDER BY created_at DESC LIMIT 1;
  RETURN v_id;
END; $fn$;

REVOKE ALL ON FUNCTION public.quiz_hunt_available() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hunt_start() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hunt_state(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hunt_answer(uuid, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hunt_my_active_session() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.quiz_hunt_available() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_start() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_state(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_answer(uuid, int, int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_my_active_session() TO authenticated, service_role;

INSERT INTO public.quiz_modes
  (agency_id, mode_key, title, description, question_count, seconds_per_question,
   allowed_shapes, is_gating, is_active, sort_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'scavenger_hunt', 'Scavenger Hunt',
       'Six passages pulled out of the manuals. Say which page each one came from.',
       6, 0, ARRAY['choice']::text[], false, true, 9
WHERE NOT EXISTS (
  SELECT 1 FROM public.quiz_modes
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND mode_key = 'scavenger_hunt');
