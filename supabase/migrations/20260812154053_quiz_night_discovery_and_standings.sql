-- Harden the answer guard: read the attempt as definer so the check can
-- never depend on what row-level security lets the caller see.
CREATE OR REPLACE FUNCTION public.quiz_answers_night_write_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_mode text;
BEGIN
  SELECT a.mode_key INTO v_mode FROM public.quiz_attempts a WHERE a.id = NEW.attempt_id;
  IF v_mode = 'trivia_night'
     AND COALESCE(current_setting('newtworks.night_write', true), '') <> '1' THEN
    RAISE EXCEPTION 'trivia night answers must go through quiz_night_answer';
  END IF;
  RETURN NEW;
END; $$;

-- Is a night running right now, and where do I stand with it?
CREATE OR REPLACE FUNCTION public.quiz_night_active()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_sess FROM public.quiz_night_sessions
   WHERE agency_id = v_agency AND status IN ('lobby','question','reveal')
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'session_id', v_sess.id,
    'status', v_sess.status,
    'is_host', (v_sess.host_team_member_id = v_member),
    'joined', EXISTS (SELECT 1 FROM public.quiz_night_players
                       WHERE session_id = v_sess.id AND team_member_id = v_member));
END; $$;

-- Call it off. Without this, one session left open blocks trivia night
-- forever, because create_session refuses while any night is live.
CREATE OR REPLACE FUNCTION public.quiz_night_abandon(p_session_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_host uuid; v_status text;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  SELECT host_team_member_id, status INTO v_host, v_status
    FROM public.quiz_night_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF v_host IS NULL THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_host <> v_member AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'only the host or an owner can call it off';
  END IF;
  IF v_status IN ('finished','abandoned') THEN RETURN; END IF;
  UPDATE public.quiz_night_sessions SET status = 'abandoned', updated_at = now()
   WHERE id = p_session_id;
END; $$;

-- The board. Opens at the reveal, never during a live question.
CREATE OR REPLACE FUNCTION public.quiz_night_standings(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_agency uuid; v_member uuid; v_status text; v_rows jsonb;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT s.status INTO v_status FROM public.quiz_night_sessions s
   WHERE s.id = p_session_id AND s.agency_id = v_agency;
  IF v_status IS NULL THEN RAISE EXCEPTION 'that trivia night was not found'; END IF;
  IF v_status NOT IN ('reveal','finished','abandoned') THEN
    RAISE EXCEPTION 'standings open up at the reveal';
  END IF;

  SELECT jsonb_agg(y.x ORDER BY (y.x->>'correct_count')::int DESC, y.x->>'name')
    INTO v_rows
    FROM (SELECT jsonb_build_object(
            'team_member_id', p.team_member_id,
            'name', t.first_name,
            'answered_count', (SELECT COUNT(*) FROM public.quiz_answers qa
                                WHERE qa.attempt_id = p.attempt_id),
            'correct_count', (SELECT COUNT(*) FROM public.quiz_answers qa
                                JOIN public.quiz_item_options o ON o.id = qa.chosen_option_id
                               WHERE qa.attempt_id = p.attempt_id AND o.is_correct),
            'points', (SELECT SUM(qa.points) FROM public.quiz_answers qa
                        WHERE qa.attempt_id = p.attempt_id),
            'is_me', (p.team_member_id = v_member)) AS x
            FROM public.quiz_night_players p
            LEFT JOIN public.team t ON t.id = p.team_member_id
           WHERE p.session_id = p_session_id) y;
  RETURN COALESCE(v_rows, '[]'::jsonb);
END; $$;

REVOKE ALL ON FUNCTION public.quiz_night_active() FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_abandon(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_night_standings(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.quiz_night_active() TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_abandon(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_night_standings(uuid) TO authenticated;
