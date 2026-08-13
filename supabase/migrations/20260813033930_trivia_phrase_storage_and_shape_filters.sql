-- Trivia: phrase storage + shape filtering on every server-side serving path.
--
-- WHY: quiz_modes.allowed_shapes has existed since the modes were seeded and
-- has never been read by any code. Every serving path took whatever was
-- approved regardless of shape, so the first non-'choice' item approved would
-- have been dealt straight into Daily Five, Duel, The Grid, Trivia Night and
-- the gated exam, all of which render multiple choice only through one shared
-- runner. This migration makes each serving path honour its own mode's
-- allowed_shapes, and adds storage for the hidden phrase that the Spin and
-- Solve mode needs.
--
-- PHRASE STORAGE DECISION (Peter, 2026-08-13): the hidden phrase lives in a new
-- nullable column on quiz_items, NOT as a single row in quiz_item_options. A
-- Spin and Solve item is two-part -- solve the hidden term, then answer what it
-- means -- so it keeps a normal four-option/one-correct meaning question and
-- carries the phrase alongside. Consequence: the approval guard
-- quiz_items_require_valid_options needs NO change, because a phrase item still
-- satisfies four options with one correct.

-- ---------------------------------------------------------------------------
-- 1. Phrase storage
-- ---------------------------------------------------------------------------
ALTER TABLE public.quiz_items
  ADD COLUMN IF NOT EXISTS phrase_answer text;

COMMENT ON COLUMN public.quiz_items.phrase_answer IS
  'The hidden term a player solves in Spin and Solve. Filled only when shape = phrase. Letters, spaces, apostrophes and hyphens only so letter-by-letter guessing has clean text to work against.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.quiz_items'::regclass
                    AND conname = 'quiz_items_phrase_answer_shape_check') THEN
    ALTER TABLE public.quiz_items
      ADD CONSTRAINT quiz_items_phrase_answer_shape_check
      CHECK ( (shape = 'phrase') = (phrase_answer IS NOT NULL) );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.quiz_items'::regclass
                    AND conname = 'quiz_items_phrase_answer_format_check') THEN
    ALTER TABLE public.quiz_items
      ADD CONSTRAINT quiz_items_phrase_answer_format_check
      CHECK ( phrase_answer IS NULL
              OR ( length(phrase_answer) BETWEEN 3 AND 60
                   AND phrase_answer ~ '^[A-Za-z][A-Za-z ''-]*$' ) );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Trivia Night selection honours its mode's allowed_shapes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_night_start(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_sess public.quiz_night_sessions;
  v_count int; v_shapes text[]; v_ids uuid[]; v_players int := 0;
  v_p record; v_attempt uuid;
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

  SELECT question_count, COALESCE(allowed_shapes, ARRAY['choice']::text[])
    INTO v_count, v_shapes
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'trivia_night';

  SELECT array_agg(x.id) INTO v_ids FROM (
    SELECT qi.id FROM public.quiz_items qi
     WHERE qi.agency_id = v_agency AND qi.status = 'approved'
       AND qi.report_blocked = false
       AND qi.shape = ANY (v_shapes)
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
END; $function$;

-- ---------------------------------------------------------------------------
-- 3. The Grid board build honours its mode's allowed_shapes
--    Two places: the column picker and the per-column clue draw.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_start_grid_attempt()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_existing uuid; v_fin timestamptz;
  v_cats text[]; v_cat text; v_items jsonb; v_shapes text[];
  v_board jsonb := '[]'::jsonb; v_points jsonb := '[]'::jsonb;
  v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  -- One board per person per Central-time day. Unfinished one resumes
  -- with its pinned board; a finished one refuses.
  SELECT id, finished_at INTO v_existing, v_fin
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'the_grid'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date);
  IF v_existing IS NOT NULL THEN
    IF v_fin IS NOT NULL THEN
      RAISE EXCEPTION 'the board is once a day - come back tomorrow';
    END IF;
    RETURN v_existing;
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['choice']::text[]) INTO v_shapes
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'the_grid';
  IF v_shapes IS NULL THEN v_shapes := ARRAY['choice']::text[]; END IF;

  SELECT array_agg(c.category ORDER BY c.n DESC, c.category)
    INTO v_cats
    FROM (SELECT qi.category, COUNT(*) AS n
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false AND qi.category IS NOT NULL
             AND qi.shape = ANY (v_shapes)
           GROUP BY qi.category
          HAVING COUNT(*) >= 5
           ORDER BY COUNT(*) DESC, qi.category
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
                   AND qi.shape = ANY (v_shapes)
                 ORDER BY random() LIMIT 5) p
      ) y;

    v_board  := v_board || jsonb_build_array(
                  jsonb_build_object('category', v_cat, 'clues', v_items));
    v_points := v_points || v_items;
  END LOOP;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'the_grid',
          jsonb_build_object(
            'board', v_board,
            'board_points', v_points,
            'item_ids', (SELECT jsonb_agg(e->'item_id')
                           FROM jsonb_array_elements(v_points) e)))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

-- ---------------------------------------------------------------------------
-- 4. Topic-set pool takes a shape list. Default is choice-only so the one
--    existing caller (the Gates tab pool preview, which passes p_set_id only)
--    keeps its current behaviour without change. The gating modes pass their
--    own allowed_shapes explicitly from quiz_start_gated_attempt.
--    Signature changes, so this is a drop-and-create, not a replace; grants
--    are restored to match the pre-existing access exactly.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.quiz_topic_set_pool(uuid);

CREATE OR REPLACE FUNCTION public.quiz_topic_set_pool(
  p_set_id uuid,
  p_shapes text[] DEFAULT ARRAY['choice']::text[]
)
 RETURNS TABLE(item_id uuid)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT DISTINCT qi.id
    FROM public.quiz_items qi
    JOIN public.quiz_topic_sets ts
      ON ts.id = p_set_id AND ts.agency_id = qi.agency_id
   WHERE ts.agency_id IN (SELECT u.agency_id FROM public.users u
                           WHERE u.auth_user_id = auth.uid())
     AND qi.status = 'approved' AND qi.report_blocked = false
     AND qi.shape = ANY (COALESCE(p_shapes, ARRAY['choice']::text[]))
     AND EXISTS (
       SELECT 1 FROM public.quiz_topic_set_rules r
        WHERE r.set_id = p_set_id
          AND ( r.item_id = qi.id
                OR ( r.item_id IS NULL
                     AND (r.category   IS NULL OR r.category   = qi.category)
                     AND (r.difficulty IS NULL OR r.difficulty = qi.difficulty) ) )
     );
$function$;

REVOKE ALL ON FUNCTION public.quiz_topic_set_pool(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_topic_set_pool(uuid, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_topic_set_pool(uuid, text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. The two gating modes pass their own allowed_shapes into the pool
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_start_gated_attempt(p_mode_key text, p_topic_set_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_mode public.quiz_modes;
  v_ids uuid[]; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_mode FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = p_mode_key
     AND is_gating = true AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'not a gating mode'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.quiz_topic_sets
                  WHERE id = p_topic_set_id AND agency_id = v_agency
                    AND is_active = true) THEN
    RAISE EXCEPTION 'topic set not found or inactive';
  END IF;

  SELECT array_agg(x.item_id) INTO v_ids FROM (
    SELECT pool.item_id
      FROM public.quiz_topic_set_pool(
             p_topic_set_id,
             COALESCE(v_mode.allowed_shapes, ARRAY['choice']::text[])) pool
     ORDER BY random() LIMIT v_mode.question_count
  ) x;
  IF v_ids IS NULL OR array_length(v_ids, 1) < v_mode.question_count THEN
    RAISE EXCEPTION 'not enough approved questions in this topic set yet (need %, have %)',
      v_mode.question_count, COALESCE(array_length(v_ids, 1), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, topic_set_id, context)
  VALUES (v_agency, v_member, p_mode_key, p_topic_set_id,
          jsonb_build_object('item_ids', to_jsonb(v_ids),
                             'topic_set_id', p_topic_set_id))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;
