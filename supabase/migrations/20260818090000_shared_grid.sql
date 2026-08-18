-- Shared Grid: one shared-screen live game of The Grid with named players,
-- turns, and server-authoritative per-player scoring.
-- Named players are typed labels for the room, NOT signed-in team members —
-- only the host needs to be signed in. One row per game night is the whole
-- state; no cross-device realtime needed because it is a single shared screen.

CREATE TABLE IF NOT EXISTS public.quiz_grid_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  host_team_member_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active',
  players jsonb NOT NULL DEFAULT '[]'::jsonb,
  board jsonb NOT NULL,
  board_points jsonb NOT NULL,
  answered_item_ids uuid[] NOT NULL DEFAULT '{}',
  current_player_index int NOT NULL DEFAULT 0,
  active_item_id uuid NULL,
  active_revealed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.quiz_grid_sessions ENABLE ROW LEVEL SECURITY;
-- Zero policies, deny-all by design — same convention as quiz_night_sessions.
-- Every read and write goes through the SECURITY DEFINER functions below.

CREATE INDEX IF NOT EXISTS ix_quiz_grid_sessions_agency_status
  ON public.quiz_grid_sessions(agency_id, status);

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_start(p_player_names text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_names text[]; v_players jsonb := '[]'::jsonb;
  v_name text; v_cats text[]; v_cat text; v_items jsonb;
  v_board jsonb := '[]'::jsonb; v_points jsonb := '[]'::jsonb; v_new uuid;
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

  -- Board build is the same rule as the single-player Grid (quiz_start_grid_attempt):
  -- 5 categories with >=5 approved choice-shape questions each, 5 clues per
  -- category worth 10/20/30/40/50 ordered by difficulty. Under 3 qualifying
  -- categories the mode refuses.
  SELECT array_agg(c.category)
    INTO v_cats
    FROM (SELECT qi.category
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
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
    SELECT jsonb_agg(jsonb_build_object('item_id', y.id, 'points', y.rn * 10)
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
                 WHERE qi.agency_id = v_agency AND qi.status = 'approved'
                   AND qi.report_blocked = false AND qi.category = v_cat
                   AND qi.shape = 'choice'
                 ORDER BY random() LIMIT 5) p
      ) y;

    v_board  := v_board || jsonb_build_array(
                  jsonb_build_object('category', v_cat, 'clues', v_items));
    v_points := v_points || v_items;
  END LOOP;

  INSERT INTO public.quiz_grid_sessions
    (agency_id, host_team_member_id, players, board, board_points, current_player_index)
  VALUES (v_agency, v_member, v_players, v_board, v_points, 0)
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_start(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_start(text[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_board jsonb; v_question jsonb;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;

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
    'session_id', v_sess.id, 'status', v_sess.status,
    'is_host', (v_sess.host_team_member_id = v_member),
    'players', v_sess.players,
    'current_player_index', v_sess.current_player_index,
    'board', v_board,
    'active_item_id', v_sess.active_item_id,
    'active_revealed', v_sess.active_revealed,
    'question', v_question);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_state(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_pick(p_session_id uuid, p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can pick a square'; END IF;
  IF v_sess.status <> 'active' THEN RAISE EXCEPTION 'this game is over'; END IF;
  IF v_sess.active_item_id IS NOT NULL THEN RAISE EXCEPTION 'finish the square on screen first'; END IF;
  IF p_item_id = ANY (v_sess.answered_item_ids) THEN RAISE EXCEPTION 'that square is already gone'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sess.board_points) e
                  WHERE (e->>'item_id')::uuid = p_item_id) THEN
    RAISE EXCEPTION 'that square is not on this board';
  END IF;

  UPDATE public.quiz_grid_sessions
     SET active_item_id = p_item_id, active_revealed = false, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_pick(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_pick(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_reveal(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can reveal the answer'; END IF;
  IF v_sess.active_item_id IS NULL THEN RAISE EXCEPTION 'no square is on screen'; END IF;
  IF v_sess.active_revealed THEN RAISE EXCEPTION 'already revealed'; END IF;

  UPDATE public.quiz_grid_sessions
     SET active_revealed = true, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_reveal(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_reveal(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- p_winner_index NULL means nobody got it right — turn passes to the next
-- player in order. A winner's index becomes the new current turn (Jeopardy
-- convention: whoever answers correctly picks next).
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_score(p_session_id uuid, p_winner_index int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_grid_sessions;
  v_points int; v_players jsonb; v_next int; v_answered uuid[];
  v_total_clues int; v_status text; v_player_count int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can score a square'; END IF;
  IF v_sess.active_item_id IS NULL THEN RAISE EXCEPTION 'no square is on screen'; END IF;
  IF NOT v_sess.active_revealed THEN RAISE EXCEPTION 'reveal the answer before scoring it'; END IF;

  v_player_count := jsonb_array_length(v_sess.players);

  SELECT (e->>'points')::int INTO v_points
    FROM jsonb_array_elements(v_sess.board_points) e
   WHERE (e->>'item_id')::uuid = v_sess.active_item_id;

  v_players := v_sess.players;
  IF p_winner_index IS NOT NULL THEN
    IF p_winner_index < 0 OR p_winner_index >= v_player_count THEN
      RAISE EXCEPTION 'that player is not on the board';
    END IF;
    v_players := jsonb_set(v_players, ARRAY[p_winner_index::text, 'score'],
                   to_jsonb(COALESCE((v_players -> p_winner_index ->> 'score')::int, 0) + v_points));
    v_next := p_winner_index;
  ELSE
    v_next := (v_sess.current_player_index + 1) % v_player_count;
  END IF;

  v_answered := v_sess.answered_item_ids || ARRAY[v_sess.active_item_id];
  v_total_clues := jsonb_array_length(v_sess.board_points);
  v_status := CASE WHEN array_length(v_answered, 1) >= v_total_clues THEN 'finished' ELSE 'active' END;

  UPDATE public.quiz_grid_sessions
     SET players = v_players,
         answered_item_ids = v_answered,
         current_player_index = v_next,
         active_item_id = NULL,
         active_revealed = false,
         status = v_status,
         updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true, 'status', v_status, 'points_awarded', v_points);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_score(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_score(uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_end(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_agency uuid; v_member uuid; v_host uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT host_team_member_id INTO v_host FROM public.quiz_grid_sessions
   WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid game was not found'; END IF;
  IF v_host <> v_member THEN RAISE EXCEPTION 'only the host can end this game'; END IF;

  UPDATE public.quiz_grid_sessions
     SET status = 'finished', active_item_id = NULL, active_revealed = false, updated_at = now()
   WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_end(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_end(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- Lets a host resume an in-progress shared grid game without needing the
-- session id (e.g. after a refresh) — same convenience quiz_night gives.
CREATE OR REPLACE FUNCTION public.quiz_shared_grid_my_active_session()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_agency uuid; v_member uuid; v_id uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT id INTO v_id FROM public.quiz_grid_sessions
   WHERE agency_id = v_agency AND host_team_member_id = v_member AND status = 'active'
   ORDER BY created_at DESC LIMIT 1;
  RETURN v_id;
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_shared_grid_my_active_session() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_shared_grid_my_active_session() TO authenticated, service_role;
