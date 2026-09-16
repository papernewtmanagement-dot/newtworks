-- Hangman: shared-screen room word game over the approved hidden-term items.
-- Same convention as Shared Grid: RLS on with zero policies (deny all), every
-- read and write through SECURITY DEFINER functions granted to authenticated.

CREATE TABLE IF NOT EXISTS public.quiz_hangman_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  host_team_member_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active',
  players jsonb NOT NULL DEFAULT '[]'::jsonb,
  current_player_index int NOT NULL DEFAULT 0,
  item_id uuid,
  phrase text NOT NULL,
  guessed_letters text[] NOT NULL DEFAULT '{}'::text[],
  misses int NOT NULL DEFAULT 0,
  max_misses int NOT NULL DEFAULT 6,
  round int NOT NULL DEFAULT 1,
  round_over boolean NOT NULL DEFAULT false,
  solved boolean NOT NULL DEFAULT false,
  used_item_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.quiz_hangman_sessions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_quiz_hangman_sessions_host
  ON public.quiz_hangman_sessions (agency_id, host_team_member_id, status);

-- Masked view of the term: letters that have been called show, everything else
-- that is a letter shows as an underscore, spaces and punctuation always show.
CREATE OR REPLACE FUNCTION public._quiz_hangman_mask(p_phrase text, p_guessed text[])
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $fn$
  SELECT COALESCE(string_agg(
    CASE WHEN t.ch ~ '[A-Z]' AND NOT (t.ch = ANY (COALESCE(p_guessed, '{}'::text[])))
         THEN '_' ELSE t.ch END, '' ORDER BY t.ord), '')
  FROM regexp_split_to_table(upper(COALESCE(p_phrase, '')), '') WITH ORDINALITY AS t(ch, ord);
$fn$;

REVOKE ALL ON FUNCTION public._quiz_hangman_mask(text, text[]) FROM PUBLIC;

-- Comparison form for a solve attempt: letters and digits only.
CREATE OR REPLACE FUNCTION public._quiz_hangman_norm(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $fn$
  SELECT regexp_replace(upper(COALESCE(p_text, '')), '[^A-Z0-9]', '', 'g');
$fn$;

REVOKE ALL ON FUNCTION public._quiz_hangman_norm(text) FROM PUBLIC;

-- The jsonb the screen runs on. The answer itself is only ever included once
-- the round is over.
CREATE OR REPLACE FUNCTION public._quiz_hangman_state_row(p_sess public.quiz_hangman_sessions)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE v_item public.quiz_items; v_mask text;
BEGIN
  SELECT * INTO v_item FROM public.quiz_items WHERE id = p_sess.item_id;
  v_mask := public._quiz_hangman_mask(p_sess.phrase, p_sess.guessed_letters);
  RETURN jsonb_build_object(
    'id', p_sess.id,
    'status', p_sess.status,
    'players', p_sess.players,
    'current_player_index', p_sess.current_player_index,
    'masked', v_mask,
    'guessed_letters', to_jsonb(p_sess.guessed_letters),
    'misses', p_sess.misses,
    'max_misses', p_sess.max_misses,
    'round', p_sess.round,
    'round_over', p_sess.round_over,
    'solved', p_sess.solved,
    'category', v_item.category,
    'letters_left', (length(v_mask) - length(replace(v_mask, '_', ''))),
    'phrase', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN upper(p_sess.phrase) ELSE NULL END,
    'stem', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN v_item.stem ELSE NULL END,
    'explanation', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN v_item.explanation ELSE NULL END
  );
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hangman_state_row(public.quiz_hangman_sessions) FROM PUBLIC;

-- Draws a term nobody in this game has had yet.
CREATE OR REPLACE FUNCTION public._quiz_hangman_draw(p_agency uuid, p_used uuid[])
RETURNS public.quiz_items LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE v_item public.quiz_items;
BEGIN
  SELECT * INTO v_item FROM public.quiz_items i
   WHERE i.agency_id = p_agency AND i.shape = 'phrase' AND i.status = 'approved'
     AND i.phrase_answer IS NOT NULL
     AND NOT (i.id = ANY (COALESCE(p_used, '{}'::uuid[])))
   ORDER BY random() LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_item FROM public.quiz_items i
     WHERE i.agency_id = p_agency AND i.shape = 'phrase' AND i.status = 'approved'
       AND i.phrase_answer IS NOT NULL
     ORDER BY random() LIMIT 1;
  END IF;

  IF NOT FOUND THEN RAISE EXCEPTION 'there are no hidden terms to play yet'; END IF;
  RETURN v_item;
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hangman_draw(uuid, uuid[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.quiz_hangman_start(p_player_names text[])
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_agency uuid; v_member uuid; v_names text[]; v_players jsonb := '[]'::jsonb;
  v_name text; v_item public.quiz_items; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT array_agg(NULLIF(trim(x), '')) INTO v_names
    FROM unnest(p_player_names) x WHERE NULLIF(trim(x), '') IS NOT NULL;
  IF v_names IS NULL OR array_length(v_names, 1) < 1 THEN
    RAISE EXCEPTION 'name at least one player';
  END IF;
  IF array_length(v_names, 1) > 8 THEN
    RAISE EXCEPTION 'eight players is the most one game can hold';
  END IF;

  FOREACH v_name IN ARRAY v_names LOOP
    v_players := v_players || jsonb_build_array(jsonb_build_object('name', v_name, 'score', 0));
  END LOOP;

  v_item := public._quiz_hangman_draw(v_agency, '{}'::uuid[]);

  INSERT INTO public.quiz_hangman_sessions
    (agency_id, host_team_member_id, players, item_id, phrase, used_item_ids)
  VALUES (v_agency, v_member, v_players, v_item.id, upper(v_item.phrase_answer), ARRAY[v_item.id])
  RETURNING id INTO v_new;
  RETURN v_new;
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_state(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_sess public.quiz_hangman_sessions;
BEGIN
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO v_sess FROM public.quiz_hangman_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that game was not found'; END IF;
  RETURN public._quiz_hangman_state_row(v_sess);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_guess(p_session_id uuid, p_letter text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_hangman_sessions;
  v_letter text; v_hits int; v_players jsonb; v_next int; v_count int;
  v_mask text; v_misses int; v_over boolean := false; v_solved boolean := false;
  v_points int := 0;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_hangman_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can call a letter'; END IF;
  IF v_sess.status <> 'active' THEN RAISE EXCEPTION 'that game is over'; END IF;
  IF v_sess.round_over THEN RAISE EXCEPTION 'this round is over — start the next term'; END IF;

  v_letter := upper(trim(COALESCE(p_letter, '')));
  IF v_letter !~ '^[A-Z]$' THEN RAISE EXCEPTION 'call a single letter'; END IF;
  IF v_letter = ANY (v_sess.guessed_letters) THEN RAISE EXCEPTION 'that letter has already been called'; END IF;

  v_count := jsonb_array_length(v_sess.players);
  v_players := v_sess.players;
  v_hits := length(upper(v_sess.phrase)) - length(replace(upper(v_sess.phrase), v_letter, ''));
  v_misses := v_sess.misses;
  v_next := v_sess.current_player_index;

  IF v_hits > 0 THEN
    v_points := 10 * v_hits;
    v_players := jsonb_set(v_players, ARRAY[v_sess.current_player_index::text, 'score'],
      to_jsonb(COALESCE((v_players -> v_sess.current_player_index ->> 'score')::int, 0) + v_points));
  ELSE
    v_misses := v_misses + 1;
    v_next := (v_sess.current_player_index + 1) % v_count;
  END IF;

  v_mask := public._quiz_hangman_mask(v_sess.phrase, v_sess.guessed_letters || ARRAY[v_letter]);
  IF position('_' in v_mask) = 0 THEN v_solved := true; v_over := true; END IF;
  IF v_misses >= v_sess.max_misses THEN v_over := true; END IF;

  UPDATE public.quiz_hangman_sessions
     SET guessed_letters = guessed_letters || ARRAY[v_letter],
         misses = v_misses,
         players = v_players,
         current_player_index = v_next,
         round_over = v_over,
         solved = v_solved,
         updated_at = now()
   WHERE id = p_session_id
   RETURNING * INTO v_sess;

  RETURN public._quiz_hangman_state_row(v_sess)
         || jsonb_build_object('letter', v_letter, 'hits', v_hits, 'points_awarded', v_points);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_solve(p_session_id uuid, p_guess text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_hangman_sessions;
  v_right boolean; v_players jsonb; v_next int; v_count int;
  v_misses int; v_over boolean := false; v_points int := 0;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_hangman_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can enter a solve'; END IF;
  IF v_sess.status <> 'active' THEN RAISE EXCEPTION 'that game is over'; END IF;
  IF v_sess.round_over THEN RAISE EXCEPTION 'this round is over — start the next term'; END IF;

  v_count := jsonb_array_length(v_sess.players);
  v_players := v_sess.players;
  v_misses := v_sess.misses;
  v_next := v_sess.current_player_index;
  v_right := public._quiz_hangman_norm(p_guess) = public._quiz_hangman_norm(v_sess.phrase)
             AND public._quiz_hangman_norm(p_guess) <> '';

  IF v_right THEN
    v_points := 25;
    v_players := jsonb_set(v_players, ARRAY[v_sess.current_player_index::text, 'score'],
      to_jsonb(COALESCE((v_players -> v_sess.current_player_index ->> 'score')::int, 0) + v_points));
    v_over := true;
  ELSE
    v_misses := v_misses + 1;
    v_next := (v_sess.current_player_index + 1) % v_count;
    IF v_misses >= v_sess.max_misses THEN v_over := true; END IF;
  END IF;

  UPDATE public.quiz_hangman_sessions
     SET players = v_players,
         misses = v_misses,
         current_player_index = v_next,
         round_over = v_over,
         solved = v_right,
         updated_at = now()
   WHERE id = p_session_id
   RETURNING * INTO v_sess;

  RETURN public._quiz_hangman_state_row(v_sess)
         || jsonb_build_object('solve_correct', v_right, 'points_awarded', v_points);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_next_round(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_hangman_sessions;
  v_item public.quiz_items; v_count int;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_hangman_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can start the next term'; END IF;
  IF v_sess.status <> 'active' THEN RAISE EXCEPTION 'that game is over'; END IF;
  IF NOT v_sess.round_over THEN RAISE EXCEPTION 'this term is still in play'; END IF;

  v_count := jsonb_array_length(v_sess.players);
  v_item := public._quiz_hangman_draw(v_agency, v_sess.used_item_ids);

  UPDATE public.quiz_hangman_sessions
     SET item_id = v_item.id,
         phrase = upper(v_item.phrase_answer),
         used_item_ids = used_item_ids || ARRAY[v_item.id],
         guessed_letters = '{}'::text[],
         misses = 0,
         round = round + 1,
         round_over = false,
         solved = false,
         current_player_index = (v_sess.current_player_index + 1) % v_count,
         updated_at = now()
   WHERE id = p_session_id
   RETURNING * INTO v_sess;

  RETURN public._quiz_hangman_state_row(v_sess);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_finish(p_session_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_member uuid; v_sess public.quiz_hangman_sessions;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT * INTO v_sess FROM public.quiz_hangman_sessions WHERE id = p_session_id AND agency_id = v_agency;
  IF NOT FOUND THEN RAISE EXCEPTION 'that game was not found'; END IF;
  IF v_sess.host_team_member_id <> v_member THEN RAISE EXCEPTION 'only the host can end the game'; END IF;

  UPDATE public.quiz_hangman_sessions
     SET status = 'finished', round_over = true, updated_at = now()
   WHERE id = p_session_id
   RETURNING * INTO v_sess;

  RETURN public._quiz_hangman_state_row(v_sess);
END; $fn$;

CREATE OR REPLACE FUNCTION public.quiz_hangman_my_active_session()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_member uuid; v_id uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT id INTO v_id FROM public.quiz_hangman_sessions
   WHERE agency_id = v_agency AND host_team_member_id = v_member AND status = 'active'
   ORDER BY created_at DESC LIMIT 1;
  RETURN v_id;
END; $fn$;

REVOKE ALL ON FUNCTION public.quiz_hangman_start(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_state(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_guess(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_solve(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_next_round(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_finish(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_hangman_my_active_session() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.quiz_hangman_start(text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_state(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_guess(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_solve(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_next_round(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_finish(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.quiz_hangman_my_active_session() TO authenticated, service_role;

INSERT INTO public.quiz_modes
  (agency_id, mode_key, title, description, question_count, seconds_per_question,
   allowed_shapes, is_gating, is_active, sort_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'hangman', 'Hangman',
       'One screen, named players, six wrong guesses. Call letters to uncover the term.',
       1, 0, ARRAY['phrase']::text[], false, true, 8
WHERE NOT EXISTS (
  SELECT 1 FROM public.quiz_modes
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND mode_key = 'hangman');
