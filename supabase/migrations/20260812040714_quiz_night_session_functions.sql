-- Guard: a night answer may only be written by quiz_night_answer, which
-- sets a session-local flag. Blocks a browser from reporting its own
-- elapsed time and farming the speed bonus.
CREATE OR REPLACE FUNCTION public.quiz_answers_night_write_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_mode text;
BEGIN
  SELECT a.mode_key INTO v_mode FROM public.quiz_attempts a WHERE a.id = NEW.attempt_id;
  IF v_mode = 'trivia_night'
     AND COALESCE(current_setting('newtworks.night_write', true), '') <> '1' THEN
    RAISE EXCEPTION 'trivia night answers must go through quiz_night_answer';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS quiz_answers_night_write_guard ON public.quiz_answers;
CREATE TRIGGER quiz_answers_night_write_guard
  BEFORE INSERT OR UPDATE ON public.quiz_answers
  FOR EACH ROW EXECUTE FUNCTION public.quiz_answers_night_write_guard();

-- 1. Host opens a session.
CREATE OR REPLACE FUNCTION public.quiz_night_create_session()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_secs int; v_new uuid;
BEGIN
  IF NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'only an owner can start trivia night';
  END IF;
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  IF EXISTS (SELECT 1 FROM public.quiz_night_sessions
              WHERE agency_id = v_agency AND status IN ('lobby','question','reveal')) THEN
    RAISE EXCEPTION 'a trivia night is already running - finish or abandon it first';
  END IF;

  SELECT seconds_per_question INTO v_secs FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'trivia_night' AND is_active = true;
  IF v_secs IS NULL THEN RAISE EXCEPTION 'trivia night is not set up'; END IF;

  INSERT INTO public.quiz_night_sessions (agency_id, host_team_member_id, seconds_per_question)
  VALUES (v_agency, v_member, v_secs) RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

-- 2. A teammate joins the lobby.
CREATE OR REPLACE FUNCTION public.quiz_night_join(p_session_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_status text; v_id uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT status INTO v_status FROM public.quiz_night_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF v_status IS NULL THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_status <> 'lobby' THEN RAISE EXCEPTION 'this trivia night has already started'; END IF;

  INSERT INTO public.quiz_night_players (session_id, team_member_id)
  VALUES (p_session_id, v_member)
  ON CONFLICT (session_id, team_member_id) DO UPDATE SET joined_at = public.quiz_night_players.joined_at
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- 3. Host starts: draw the questions once, pin them, give every player
--    a real attempt row carrying the same list.
CREATE OR REPLACE FUNCTION public.quiz_night_start(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions;
  v_count int; v_ids uuid[]; v_players int := 0; v_p record; v_attempt uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  SELECT * INTO v_sess FROM public.quiz_night_sessions
   WHERE id = p_session_id AND agency_id = v_agency FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN
    RAISE EXCEPTION 'only the host can start this trivia night';
  END IF;
  IF v_sess.status <> 'lobby' THEN RAISE EXCEPTION 'this trivia night has already started'; END IF;

  SELECT COUNT(*) INTO v_players FROM public.quiz_night_players WHERE session_id = p_session_id;
  IF v_players < 1 THEN RAISE EXCEPTION 'nobody has joined yet'; END IF;

  SELECT question_count INTO v_count FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'trivia_night';

  SELECT array_agg(x.id) INTO v_ids FROM (
    SELECT qi.id FROM public.quiz_items qi
     WHERE qi.agency_id = v_agency AND qi.status = 'approved'
       AND qi.report_blocked = false
     ORDER BY random() LIMIT v_count) x;

  IF v_ids IS NULL OR array_length(v_ids,1) < v_count THEN
    RAISE EXCEPTION 'not enough approved questions for a trivia night yet (need %, have %)',
      v_count, COALESCE(array_length(v_ids,1),0);
  END IF;

  FOR v_p IN SELECT * FROM public.quiz_night_players WHERE session_id = p_session_id LOOP
    INSERT INTO public.quiz_attempts (agency_id, team_member_id, mode_key, context)
    VALUES (v_agency, v_p.team_member_id, 'trivia_night',
            jsonb_build_object('item_ids', to_jsonb(v_ids), 'night_session_id', p_session_id))
    RETURNING id INTO v_attempt;
    UPDATE public.quiz_night_players SET attempt_id = v_attempt WHERE id = v_p.id;
  END LOOP;

  UPDATE public.quiz_night_sessions
     SET item_ids = to_jsonb(v_ids), status = 'question', current_index = 0,
         current_started_at = now(), updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('players', v_players, 'question_count', v_count);
END; $$;

-- 4. A player answers. The clock comes from the session, never the browser.
CREATE OR REPLACE FUNCTION public.quiz_night_answer(p_session_id uuid, p_option_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions;
  v_attempt uuid; v_item uuid; v_secs int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  SELECT * INTO v_sess FROM public.quiz_night_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_sess.status <> 'question' THEN RAISE EXCEPTION 'not taking answers right now'; END IF;

  SELECT attempt_id INTO v_attempt FROM public.quiz_night_players
   WHERE session_id = p_session_id AND team_member_id = v_member;
  IF v_attempt IS NULL THEN RAISE EXCEPTION 'you are not in this trivia night'; END IF;

  v_item := ((v_sess.item_ids -> v_sess.current_index) #>> '{}')::uuid;
  IF v_item IS NULL THEN RAISE EXCEPTION 'no question is on screen'; END IF;

  IF EXISTS (SELECT 1 FROM public.quiz_answers
              WHERE attempt_id = v_attempt AND item_id = v_item) THEN
    RAISE EXCEPTION 'you already answered this one';
  END IF;

  IF p_option_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.quiz_item_options o
        WHERE o.id = p_option_id AND o.item_id = v_item) THEN
    RAISE EXCEPTION 'that answer does not belong to this question';
  END IF;

  v_secs := LEAST(GREATEST(FLOOR(EXTRACT(EPOCH FROM (now() - v_sess.current_started_at)))::int, 0),
                  v_sess.seconds_per_question);

  PERFORM set_config('newtworks.night_write', '1', true);
  INSERT INTO public.quiz_answers (attempt_id, item_id, chosen_option_id, seconds_taken)
  VALUES (v_attempt, v_item, p_option_id, v_secs);
  PERFORM set_config('newtworks.night_write', '0', true);

  RETURN jsonb_build_object('accepted', true, 'seconds_taken', v_secs);
END; $$;

-- 5. Host advances: question -> reveal -> next question -> ... -> finished.
CREATE OR REPLACE FUNCTION public.quiz_night_advance(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions; v_total int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  SELECT * INTO v_sess FROM public.quiz_night_sessions
   WHERE id = p_session_id AND agency_id = v_agency FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN
    RAISE EXCEPTION 'only the host can run this trivia night';
  END IF;

  v_total := COALESCE(jsonb_array_length(v_sess.item_ids), 0);

  IF v_sess.status = 'question' THEN
    UPDATE public.quiz_night_sessions SET status = 'reveal', updated_at = now()
     WHERE id = p_session_id;
    RETURN jsonb_build_object('status','reveal','index',v_sess.current_index);
  ELSIF v_sess.status = 'reveal' THEN
    IF v_sess.current_index + 1 < v_total THEN
      UPDATE public.quiz_night_sessions
         SET status = 'question', current_index = v_sess.current_index + 1,
             current_started_at = now(), updated_at = now()
       WHERE id = p_session_id;
      RETURN jsonb_build_object('status','question','index',v_sess.current_index + 1);
    ELSE
      UPDATE public.quiz_night_sessions SET status = 'finished', updated_at = now()
       WHERE id = p_session_id;
      RETURN jsonb_build_object('status','finished');
    END IF;
  ELSE
    RAISE EXCEPTION 'this trivia night is not running';
  END IF;
END; $$;

-- 6. The one read screens poll. NEVER leaks the right answer while the
--    status is question — only at reveal.
CREATE OR REPLACE FUNCTION public.quiz_night_state(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions;
  v_item uuid; v_reveal boolean; v_question jsonb; v_players jsonb; v_left int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_night_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;

  v_reveal := (v_sess.status = 'reveal');
  v_item := ((v_sess.item_ids -> v_sess.current_index) #>> '{}')::uuid;

  IF v_item IS NOT NULL AND v_sess.status IN ('question','reveal') THEN
    SELECT jsonb_build_object(
             'item_id', qi.id, 'stem', qi.stem, 'category', qi.category,
             'difficulty', qi.difficulty,
             'explanation', CASE WHEN v_reveal THEN qi.explanation ELSE NULL END,
             'options', (SELECT jsonb_agg(jsonb_build_object(
                                  'id', o.id, 'option_text', o.option_text,
                                  'is_correct', CASE WHEN v_reveal THEN o.is_correct ELSE NULL END)
                                ORDER BY o.sort_order)
                           FROM public.quiz_item_options o WHERE o.item_id = qi.id))
      INTO v_question FROM public.quiz_items qi WHERE qi.id = v_item;
  END IF;

  v_left := CASE WHEN v_sess.status = 'question' AND v_sess.current_started_at IS NOT NULL
                 THEN GREATEST(v_sess.seconds_per_question
                        - FLOOR(EXTRACT(EPOCH FROM (now() - v_sess.current_started_at)))::int, 0)
                 ELSE 0 END;

  SELECT jsonb_agg(jsonb_build_object(
           'team_member_id', p.team_member_id,
           'name', t.first_name,
           'answered_current', EXISTS (SELECT 1 FROM public.quiz_answers qa
                                        WHERE qa.attempt_id = p.attempt_id AND qa.item_id = v_item),
           'answered_count', (SELECT COUNT(*) FROM public.quiz_answers qa
                               WHERE qa.attempt_id = p.attempt_id),
           'is_me', (p.team_member_id = v_member))
         ORDER BY t.first_name)
    INTO v_players
    FROM public.quiz_night_players p
    LEFT JOIN public.team t ON t.id = p.team_member_id
   WHERE p.session_id = p_session_id;

  RETURN jsonb_build_object(
    'session_id', v_sess.id, 'status', v_sess.status,
    'is_host', (v_sess.host_team_member_id = v_member),
    'current_index', v_sess.current_index,
    'question_total', COALESCE(jsonb_array_length(v_sess.item_ids), 0),
    'seconds_per_question', v_sess.seconds_per_question,
    'seconds_left', v_left,
    'my_attempt_id', (SELECT attempt_id FROM public.quiz_night_players
                       WHERE session_id = p_session_id AND team_member_id = v_member),
    'question', v_question,
    'players', COALESCE(v_players, '[]'::jsonb));
END; $$;

REVOKE ALL ON FUNCTION public.quiz_night_create_session() FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_join(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_start(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_answer(uuid, uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_advance(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_state(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.quiz_night_create_session() TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_join(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_start(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_answer(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_advance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_state(uuid) TO authenticated;
