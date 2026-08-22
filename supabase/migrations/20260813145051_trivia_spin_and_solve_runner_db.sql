-- Spin and Solve wave, step 3: the runner's database side.
--
-- Three things, all additive:
--   1. quiz_answers gains two FACTS about the hidden-term half of a phrase
--      item: was it solved, and how many wrong guesses it took. Facts only.
--      The browser reports them; the points are worked out on the server.
--   2. quiz_finish_attempt gains ONE extra expression on the points line so
--      solving the term pays. Added by anchor, outside the right/wrong branch,
--      so the solve bonus lands even when the meaning answer is missed. The
--      trivia-night speed formula and The Grid's board points are untouched.
--   3. quiz_start_spin_attempt() — Spin and Solve's own selection path,
--      modelled on quiz_start_grid_attempt: one game per person per
--      Central-time day, shape read off the mode row rather than hardcoded.

ALTER TABLE public.quiz_answers
  ADD COLUMN IF NOT EXISTS phrase_solved boolean;

ALTER TABLE public.quiz_answers
  ADD COLUMN IF NOT EXISTS phrase_misses smallint;

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'quiz_answers_phrase_misses_check'
                    AND conrelid = 'public.quiz_answers'::regclass) THEN
    ALTER TABLE public.quiz_answers
      ADD CONSTRAINT quiz_answers_phrase_misses_check
      CHECK (phrase_misses IS NULL OR (phrase_misses >= 0 AND phrase_misses <= 5));
  END IF;
END
$do$;

COMMENT ON COLUMN public.quiz_answers.phrase_solved IS
  'Spin and Solve only. True when the player solved the hidden term before running out of wrong guesses. NULL on every other mode.';
COMMENT ON COLUMN public.quiz_answers.phrase_misses IS
  'Spin and Solve only. Count of wrong letters plus wrong whole-term guesses, 0-5. Five ends the guessing. Feeds the solve bonus in quiz_finish_attempt.';

CREATE OR REPLACE FUNCTION public.quiz_finish_attempt(p_attempt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_att        public.quiz_attempts;
  v_mode       public.quiz_modes;
  v_agency     uuid;
  v_member     uuid;
  v_correct    int;
  v_total      int;
  v_points     int;
  v_passed     boolean := NULL;
  v_day        date;
  v_dow        int;
  v_week_start date;
  v_week_sat   date;
  v_week_pts   int := 0;
  v_label      text;
  v_on_board   boolean := false;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'attempt not found or not yours'; END IF;

  SELECT * INTO v_mode FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = v_att.mode_key;

  IF v_att.finished_at IS NOT NULL THEN
    RETURN jsonb_build_object('already_finished', true,
      'correct_count', v_att.correct_count,
      'question_count', v_att.question_count,
      'points_earned', v_att.points_earned,
      'passed', v_att.passed,
      'passing_score', v_mode.passing_score);
  END IF;

  UPDATE public.quiz_answers a
     SET was_correct = EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct),
         points = CASE WHEN COALESCE(a.phrase_solved, false)
            THEN 10 + GREATEST(0, 4 - LEAST(COALESCE(a.phrase_misses, 4), 4))
            ELSE 0 END
 + CASE WHEN EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct)
            THEN (COALESCE((SELECT (bp->>'points')::int
                    FROM jsonb_array_elements(v_att.context->'board_points') bp
                   WHERE (bp->>'item_id')::uuid = a.item_id LIMIT 1), 10)
 + CASE WHEN v_att.mode_key = 'trivia_night'
        THEN GREATEST(0, round(10.0
             * (COALESCE(v_mode.seconds_per_question, 20)
                - LEAST(COALESCE(a.seconds_taken, COALESCE(v_mode.seconds_per_question, 20)),
                        COALESCE(v_mode.seconds_per_question, 20)))::numeric
             / GREATEST(COALESCE(v_mode.seconds_per_question, 20), 1))::int)
        ELSE 0 END) ELSE 0 END
   WHERE a.attempt_id = p_attempt_id;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE was_correct), COALESCE(SUM(points),0)
    INTO v_total, v_correct, v_points
    FROM public.quiz_answers WHERE attempt_id = p_attempt_id;

  IF COALESCE(v_mode.is_gating, false) AND v_mode.passing_score IS NOT NULL THEN
    v_passed := (v_total > 0
                 AND (v_correct * 100.0 / v_total) >= v_mode.passing_score);
  END IF;

  UPDATE public.quiz_items qi
     SET times_served  = qi.times_served + 1,
         times_correct = qi.times_correct + CASE WHEN a.was_correct THEN 1 ELSE 0 END,
         updated_at    = now()
    FROM public.quiz_answers a
   WHERE a.attempt_id = p_attempt_id AND qi.id = a.item_id AND qi.agency_id = v_agency;

  UPDATE public.quiz_attempts
     SET finished_at = now(), question_count = v_total,
         correct_count = v_correct, points_earned = v_points,
         score = v_points, passed = v_passed
   WHERE id = p_attempt_id;

  IF NOT COALESCE(v_mode.is_gating, false) THEN
    v_day        := v_att.attempt_day;
    v_dow        := EXTRACT(DOW FROM v_day)::int;
    v_week_start := v_day - v_dow;
    v_week_sat   := v_week_start + 6;
    v_label      := 'Trivia week of ' || to_char(v_week_sat, 'Mon DD, YYYY');

    SELECT COALESCE(SUM(qa.points_earned),0) INTO v_week_pts
      FROM public.quiz_attempts qa
      JOIN public.quiz_modes qm
        ON qm.agency_id = qa.agency_id AND qm.mode_key = qa.mode_key
     WHERE qa.agency_id = v_agency AND qa.team_member_id = v_member
       AND qa.finished_at IS NOT NULL
       AND qm.is_gating = false
       AND qa.attempt_day BETWEEN v_week_start AND v_week_sat;

    IF v_week_pts > 0 THEN
      DELETE FROM public.leaderboards
       WHERE agency_id = v_agency AND category = 'trivia_week_points'
         AND team_member_id = v_member AND record_period_label = v_label;

      WITH combined AS (
        SELECT team_member_id, record_value, record_period_label, set_at
          FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        UNION ALL
        SELECT v_member, v_week_pts::numeric, v_label, now()
      ),
      ranked AS (
        SELECT *, ROW_NUMBER() OVER (ORDER BY record_value DESC, set_at DESC) AS rn
          FROM combined
      ),
      wiped AS (
        DELETE FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        RETURNING 1
      )
      INSERT INTO public.leaderboards
        (agency_id, category, tier, team_member_id, record_value,
         record_period_label, record_week_ending, set_at)
      SELECT v_agency, 'trivia_week_points', rn, team_member_id, record_value,
             record_period_label, NULL, set_at
        FROM ranked WHERE rn <= 3 AND (SELECT COUNT(*) FROM wiped) >= 0;

      v_on_board := EXISTS (SELECT 1 FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
           AND team_member_id = v_member AND record_period_label = v_label);
    END IF;
  END IF;

  RETURN jsonb_build_object('correct_count', v_correct, 'question_count', v_total,
    'points_earned', v_points, 'week_points', v_week_pts,
    'on_leaderboard', v_on_board, 'passed', v_passed,
    'passing_score', v_mode.passing_score);
END; $function$;

CREATE OR REPLACE FUNCTION public.quiz_start_spin_attempt()
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

  -- One game per person per Central-time day, the same rule The Grid uses.
  -- An unfinished game resumes on its own pinned six terms; a finished one
  -- refuses until tomorrow.
  SELECT id, finished_at INTO v_existing, v_fin
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'spin_and_solve'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date);
  IF v_existing IS NOT NULL THEN
    IF v_fin IS NOT NULL THEN
      RAISE EXCEPTION 'spin and solve is once a day - come back tomorrow';
    END IF;
    RETURN v_existing;
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['phrase']::text[]),
         COALESCE(question_count, 6)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'spin_and_solve';
  IF v_shapes IS NULL OR array_length(v_shapes, 1) IS NULL THEN
    v_shapes := ARRAY['phrase']::text[];
  END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 6; END IF;

  -- phrase_answer NOT NULL is belt-and-braces: the shape constraint already
  -- guarantees it for shape='phrase', but a future allowed_shapes edit must
  -- not be able to deal a term-less item into a hidden-term game.
  SELECT jsonb_agg(x.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency
             AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
             AND qi.phrase_answer IS NOT NULL
           ORDER BY random()
           LIMIT v_count) x;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'spin and solve needs % approved terms (have %)',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'spin_and_solve',
          jsonb_build_object('item_ids', v_ids))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_start_spin_attempt() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_start_spin_attempt() TO postgres;
GRANT EXECUTE ON FUNCTION public.quiz_start_spin_attempt() TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_start_spin_attempt() TO service_role;
