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
         points = CASE WHEN EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct)
            THEN COALESCE((SELECT (bp->>'points')::int
                    FROM jsonb_array_elements(v_att.context->'board_points') bp
                   WHERE (bp->>'item_id')::uuid = a.item_id LIMIT 1), 10) ELSE 0 END
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
END; $function$
