-- Shared Grid rounds two and three: a doubled-value second board, then a
-- wager finale. Reuses quiz_grid_sessions as the single source of truth —
-- same one-shared-screen, server-authoritative-points design as round one.

ALTER TABLE public.quiz_grid_sessions ADD COLUMN IF NOT EXISTS round int NOT NULL DEFAULT 1;
ALTER TABLE public.quiz_grid_sessions ADD COLUMN IF NOT EXISTS final_item_id uuid NULL;
ALTER TABLE public.quiz_grid_sessions ADD COLUMN IF NOT EXISTS final_wagers jsonb NOT NULL DEFAULT '{}'::jsonb;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._quiz_shared_grid_build_board(p_agency_id uuid, p_multiplier int)
 RETURNS TABLE(board jsonb, points jsonb)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cats text[]; v_cat text; v_items jsonb;
  v_board jsonb := '[]'::jsonb; v_points jsonb := '[]'::jsonb;
BEGIN
  SELECT array_agg(c.category)
    INTO v_cats
    FROM (SELECT qi.category
            FROM public.quiz_items qi
           WHERE qi.agency_id = p_agency_id AND qi.status = 'approved'
             AND qi.report_blocked = false AND qi.category IS NOT NULL
             AND qi.shape = 'choice'
           GROUP BY qi.category
          HAVING COUNT(*) >= 5
           ORDER BY random()
           LIMIT 5) c;

  IF v_cats IS NULL OR array_length(v_cats, 1) < 3 THEN
    RAISE EXCEPTION 'the board needs at least three categories with five approved questions each (have %)',
      COALESCE(array_length(v_cats, 1), 0);
  END IF;

  FOREACH v_cat IN ARRAY v_cats LOOP
    SELECT jsonb_agg(jsonb_build_object('item_id', y.id, 'points', y.rn * p_multiplier)
                     ORDER BY y.rn)
      INTO v_items
      FROM (
        SELECT p.id,
               row_number() OVER (ORDER BY CASE p.difficulty
                                             WHEN 'basic' THEN 1
                                             WHEN 'intermediate' THEN 2
                                             ELSE 3 END, p.id) AS rn
          FROM (SELECT qi.id, qi.difficulty
                  FROM public.quiz_items qi
                 WHERE qi.agency_id = p_agency_id AND qi.status = 'approved'
                   AND qi.report_blocked = false AND qi.category = v_cat
                   AND qi.shape = 'choice'
                 ORDER BY random() LIMIT 5) p
      ) y;

    v_board  := v_board || jsonb_build_array(
                  jsonb_build_object('category', v_cat, 'clues', v_items));
    v_points := v_points || v_items;
  END LOOP;

  RETURN QUERY SELECT v_board, v_points;
END; $function$;

REVOKE ALL ON FUNCTION public._quiz_shared_grid_build_board(uuid, int) FROM PUBLIC;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_start(p_player_names text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_names text[]; v_players jsonb := '[]'::jsonb;
  v_name text; v_board jsonb; v_points jsonb; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT array_agg(NULLIF(trim(x), '')) INTO v_names
    FROM unnest(p_player_names) x
   WHERE NULLIF(trim(x), '') IS NOT NULL;
  IF v_names IS NULL OR array_length(v_names, 1) < 1 THEN
    RAISE EXCEPTION 'name at least one player';
  END IF;
  IF array_length(v_names, 1) > 8 THEN
    RAISE EXCEPTION 'eight players is the most one board can hold';
  END IF;

  FOREACH v_name IN ARRAY v_names LOOP
    v_players := v_players || jsonb_build_array(jsonb_build_object('name', v_name, 'score', 0));
  END LOOP;

  SELECT b.board, b.points INTO v_board, v_points
    FROM public._quiz_shared_grid_build_board(v_agency, 10) b;

  INSERT INTO public.quiz_grid_sessions
    (agency_id, host_team_member_id, players, board, board_points, current_player_index, round)
  VALUES (v_agency, v_member, v_players, v_board, v_points, 0, 1)
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_start_round2(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_board jsonb; v_points jsonb;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can start round two'; END IF;
  IF v_sess.round <> 1 THEN RAISE EXCEPTION 'round two only follows round one'; END IF;
  IF v_sess.status <> 'finished' THEN RAISE EXCEPTION 'finish round one first'; END IF;

  SELECT b.board, b.points INTO v_board, v_points
    FROM public._quiz_shared_grid_build_board(v_agency, 20) b;

  UPDATE public.quiz_grid_sessions
     SET board = v_board, board_points = v_points, answered_item_ids = '{}',
         active_item_id = NULL, active_revealed = false,
         round = 2, status = 'active', updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_start_round2(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_start_round2(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_start_round3(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions; v_item uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can start the wager finale'; END IF;
  IF v_sess.round <> 2 THEN RAISE EXCEPTION 'the wager finale only follows round two'; END IF;
  IF v_sess.status <> 'finished' THEN RAISE EXCEPTION 'finish round two first'; END IF;

  SELECT qi.id INTO v_item
    FROM public.quiz_items qi
   WHERE qi.agency_id = v_agency AND qi.status = 'approved'
     AND qi.report_blocked = false AND qi.shape = 'choice'
   ORDER BY random() LIMIT 1;
  IF v_item IS NULL THEN RAISE EXCEPTION 'no approved question available for the finale'; END IF;

  UPDATE public.quiz_grid_sessions
     SET round = 3, status = 'wagering', final_item_id = v_item, final_wagers = '{}',
         active_item_id = NULL, active_revealed = false, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_start_round3(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_start_round3(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_set_wager(p_session_id uuid, p_player_index int, p_amount int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_player_count int; v_score int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can enter wagers'; END IF;
  IF v_sess.status <> 'wagering' THEN RAISE EXCEPTION 'wagers are not open right now'; END IF;

  v_player_count := jsonb_array_length(v_sess.players);
  IF p_player_index < 0 OR p_player_index >= v_player_count THEN
    RAISE EXCEPTION 'that player is not on the board';
  END IF;
  v_score := COALESCE((v_sess.players -> p_player_index ->> 'score')::int, 0);
  IF p_amount < 0 THEN RAISE EXCEPTION 'a wager cannot be negative'; END IF;
  IF p_amount > GREATEST(v_score, 0) THEN
    RAISE EXCEPTION 'cannot wager more than the % points on the board', GREATEST(v_score, 0);
  END IF;

  UPDATE public.quiz_grid_sessions
     SET final_wagers = jsonb_set(final_wagers, ARRAY[p_player_index::text], to_jsonb(p_amount)),
         updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_set_wager(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_set_wager(uuid, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_lock_wagers(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions; v_player_count int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can lock wagers'; END IF;
  IF v_sess.status <> 'wagering' THEN RAISE EXCEPTION 'wagers are not open right now'; END IF;

  v_player_count := jsonb_array_length(v_sess.players);
  IF (SELECT COUNT(*) FROM jsonb_object_keys(v_sess.final_wagers)) < v_player_count THEN
    RAISE EXCEPTION 'every player needs a wager before locking in';
  END IF;

  UPDATE public.quiz_grid_sessions
     SET status = 'final_question', active_item_id = v_sess.final_item_id,
         active_revealed = false, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_lock_wagers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_lock_wagers(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_score_final(p_session_id uuid, p_correct_indexes int[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_players jsonb; v_player_count int; v_i int; v_wager int; v_score int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can score the finale'; END IF;
  IF v_sess.status <> 'final_question' THEN RAISE EXCEPTION 'not ready to score the finale'; END IF;
  IF NOT v_sess.active_revealed THEN RAISE EXCEPTION 'reveal the answer before scoring it'; END IF;

  v_players := v_sess.players;
  v_player_count := jsonb_array_length(v_players);

  FOR v_i IN 0 .. (v_player_count - 1) LOOP
    v_wager := COALESCE((v_sess.final_wagers ->> v_i::text)::int, 0);
    v_score := COALESCE((v_players -> v_i ->> 'score')::int, 0);
    IF v_i = ANY (p_correct_indexes) THEN
      v_players := jsonb_set(v_players, ARRAY[v_i::text, 'score'], to_jsonb(v_score + v_wager));
    ELSE
      v_players := jsonb_set(v_players, ARRAY[v_i::text, 'score'], to_jsonb(v_score - v_wager));
    END IF;
  END LOOP;

  UPDATE public.quiz_grid_sessions
     SET players = v_players, status = 'finished',
         active_item_id = NULL, active_revealed = false, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_score_final(uuid, int[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_score_final(uuid, int[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_board jsonb; v_question jsonb; v_final_category text;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;

  IF v_sess.round < 3 THEN
    SELECT jsonb_agg(jsonb_build_object(
             'category', col->>'category',
             'clues', (SELECT jsonb_agg(jsonb_build_object(
                                  'item_id', clue->>'item_id',
                                  'points', (clue->>'points')::int,
                                  'answered', ((clue->>'item_id')::uuid = ANY (v_sess.answered_item_ids)))
                                ORDER BY (clue->>'points')::int)
                         FROM jsonb_array_elements(col->'clues') clue)))
      INTO v_board
      FROM jsonb_array_elements(v_sess.board) col;
  END IF;

  IF v_sess.status = 'wagering' AND v_sess.final_item_id IS NOT NULL THEN
    SELECT qi.category INTO v_final_category FROM public.quiz_items qi WHERE qi.id = v_sess.final_item_id;
  END IF;

  IF v_sess.active_item_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'item_id', qi.id, 'stem', qi.stem, 'category', qi.category,
             'points', (SELECT (e->>'points')::int FROM jsonb_array_elements(v_sess.board_points) e
                         WHERE (e->>'item_id')::uuid = qi.id),
             'explanation', CASE WHEN v_sess.active_revealed THEN qi.explanation ELSE NULL END,
             'options', (SELECT jsonb_agg(jsonb_build_object(
                                  'id', o.id, 'option_text', o.option_text,
                                  'is_correct', CASE WHEN v_sess.active_revealed THEN o.is_correct ELSE NULL END)
                                ORDER BY o.sort_order)
                           FROM public.quiz_item_options o WHERE o.item_id = qi.id))
      INTO v_question FROM public.quiz_items qi WHERE qi.id = v_sess.active_item_id;
  END IF;

  RETURN jsonb_build_object(
    'session_id', v_sess.id, 'status', v_sess.status, 'round', v_sess.round,
    'is_host', (v_sess.host_team_member_id = v_member),
    'players', v_sess.players,
    'current_player_index', v_sess.current_player_index,
    'board', v_board,
    'active_item_id', v_sess.active_item_id,
    'active_revealed', v_sess.active_revealed,
    'question', v_question,
    'final_category', v_final_category,
    'final_wagers', v_sess.final_wagers);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_state(uuid) TO authenticated, service_role;

