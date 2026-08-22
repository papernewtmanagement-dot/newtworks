-- Trivia fixes, part 1: Daily Five and Duel could never start.
--
-- WHY THEY FAILED. The row-level security rule on quiz_attempts only accepts an
-- insert whose team_member_id equals current_team_member_id(), which reads the
-- signed-in person's row id out of the team table. The screen was handing it the
-- person's row id out of the users table instead. Those are two different ids for
-- every single person in this agency, so every attempt to start Daily Five or send
-- a Duel challenge was rejected with "new row violates row-level security policy
-- for table quiz_attempts". Proof it was only these two: The Grid and Spin & Solve
-- start through server-side functions that look the team id up themselves, and they
-- are the only two modes with any attempt rows at all.
--
-- THE FIX. Daily Five and Duel now start the same way every other mode does — a
-- server-side function that resolves the person itself and draws the questions
-- itself. The screen never sends an id, so the mismatch cannot come back.

CREATE OR REPLACE FUNCTION public.quiz_start_daily_attempt()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_existing uuid; v_fin timestamptz;
  v_shapes text[]; v_count int; v_ids jsonb; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  -- One set of five per person per Central-time day. An unfinished one resumes
  -- with its pinned questions; a finished one refuses.
  SELECT id, finished_at INTO v_existing, v_fin
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'daily_five'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date);
  IF v_existing IS NOT NULL THEN
    IF v_fin IS NOT NULL THEN
      RAISE EXCEPTION 'today''s five are already done - back tomorrow';
    END IF;
    RETURN v_existing;
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['choice']::text[]),
         COALESCE(question_count, 5)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'daily_five';
  IF v_shapes IS NULL THEN v_shapes := ARRAY['choice']::text[]; END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 5; END IF;

  SELECT jsonb_agg(p.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
           ORDER BY random() LIMIT v_count) p;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'not enough questions ready yet - need % , have %',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'daily_five', jsonb_build_object('item_ids', v_ids))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

GRANT EXECUTE ON FUNCTION public.quiz_start_daily_attempt() TO authenticated;

CREATE OR REPLACE FUNCTION public.quiz_start_duel_challenge(p_opponent_team_member_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_shapes text[]; v_count int;
  v_ids jsonb; v_new uuid; v_ok boolean;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;
  IF p_opponent_team_member_id = v_member THEN
    RAISE EXCEPTION 'pick someone other than yourself';
  END IF;

  -- The opponent has to be a live teammate in this agency. Without this check the
  -- screen could pass any id at all and the challenge would sit unanswerable.
  SELECT true INTO v_ok FROM public.team t
   WHERE t.id = p_opponent_team_member_id
     AND t.agency_id = v_agency AND t.is_active = true;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'that teammate is not available for a duel';
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['choice']::text[]),
         COALESCE(question_count, 7)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'duel';
  IF v_shapes IS NULL THEN v_shapes := ARRAY['choice']::text[]; END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 7; END IF;

  SELECT jsonb_agg(p.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
           ORDER BY random() LIMIT v_count) p;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'not enough questions ready yet - need % , have %',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'duel',
          jsonb_build_object('item_ids', v_ids,
                             'duel_opponent_team_member_id', p_opponent_team_member_id))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

GRANT EXECUTE ON FUNCTION public.quiz_start_duel_challenge(uuid) TO authenticated;

-- The Grid picked its five columns by "most questions first, category name as
-- tiebreak". When only three categories qualified that was the whole list anyway.
-- The bank is now fully written and twenty-six categories qualify, so that rule
-- pinned the same five columns on the board every single day and left twenty-one
-- categories unreachable. Columns are now drawn at random from everything that
-- qualifies. The five-questions-per-column floor and the three-column refusal are
-- untouched.
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

  SELECT array_agg(c.category)
    INTO v_cats
    FROM (SELECT qi.category
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false AND qi.category IS NOT NULL
             AND qi.shape = ANY (v_shapes)
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

-- Spin & Solve gave the letter-guessing half and the meaning half the same clock,
-- sixty seconds each. Guessing a coverage term from blanks with twenty-six letters
-- to choose between is far slower work than picking one of four meanings, so the
-- letter half now gets its own longer clock. The meaning half keeps sixty.
ALTER TABLE public.quiz_modes
  ADD COLUMN IF NOT EXISTS seconds_first_phase integer;

UPDATE public.quiz_modes
   SET seconds_first_phase = 150, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND mode_key = 'spin_and_solve';
