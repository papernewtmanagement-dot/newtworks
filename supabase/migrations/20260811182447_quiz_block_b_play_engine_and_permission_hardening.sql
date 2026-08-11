-- 1a. Report trigger: agency check on the UPDATE (open_question 4b38c12a)
CREATE OR REPLACE FUNCTION public.quiz_report_block_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.quiz_items
     SET report_blocked = true, updated_at = now()
   WHERE id = NEW.item_id
     AND agency_id = NEW.agency_id;
  RETURN NEW;
END; $$;

-- 1b. Report insert policy: pin agency + verify the named item belongs to it
DROP POLICY quiz_item_reports_insert ON public.quiz_item_reports;
CREATE POLICY quiz_item_reports_insert ON public.quiz_item_reports
FOR INSERT WITH CHECK (
  reported_by = public.current_team_member_id()
  AND agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
  AND EXISTS (SELECT 1 FROM public.quiz_items qi
              WHERE qi.id = quiz_item_reports.item_id
                AND qi.agency_id = quiz_item_reports.agency_id)
);

-- 1c. Attempts insert policy: pin agency (same defect class)
DROP POLICY quiz_attempts_own_insert ON public.quiz_attempts;
CREATE POLICY quiz_attempts_own_insert ON public.quiz_attempts
FOR INSERT WITH CHECK (
  team_member_id = public.current_team_member_id()
  AND agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
);

-- 1d. Tamper surface: clients only ever INSERT; drop own_update policies
DROP POLICY quiz_attempts_own_update ON public.quiz_attempts;
DROP POLICY quiz_answers_own_update ON public.quiz_answers;

-- 1e. Daily Five: DB-enforced one attempt per person per CT day (Ruling 22)
ALTER TABLE public.quiz_attempts
  ADD COLUMN IF NOT EXISTS attempt_day date NOT NULL
  DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date);
CREATE UNIQUE INDEX IF NOT EXISTS uq_quiz_attempts_daily_five
  ON public.quiz_attempts (agency_id, team_member_id, attempt_day)
  WHERE mode_key = 'daily_five';

-- 1f. Leaderboards CHECK gains the trivia category (leaderboards table
-- ONLY — the other three category CHECKs stay untouched on purpose, and
-- NO leaderboard_floor_config row is created; that keeps trivia out of
-- the audit/crossing/money loop by construction. Ruling 20.)
ALTER TABLE public.leaderboards DROP CONSTRAINT leaderboards_category_check;
ALTER TABLE public.leaderboards ADD CONSTRAINT leaderboards_category_check
  CHECK (category = ANY (ARRAY['quarter_sp'::text,'week_sp'::text,
    'week_quotes'::text,'four_week_sp'::text,'trivia_week_points'::text]));

-- 1g. Finish function: server-side truth + leaderboard post (Rulings 19+20)
CREATE OR REPLACE FUNCTION public.quiz_finish_attempt(p_attempt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_att        public.quiz_attempts;
  v_agency     uuid;
  v_member     uuid;
  v_correct    int;
  v_total      int;
  v_points     int;
  v_day        date;
  v_dow        int;
  v_week_start date;
  v_week_sat   date;
  v_week_pts   int;
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

  IF v_att.finished_at IS NOT NULL THEN
    RETURN jsonb_build_object('already_finished', true,
      'correct_count', v_att.correct_count,
      'question_count', v_att.question_count,
      'points_earned', v_att.points_earned);
  END IF;

  -- Server derives correctness; a lying client changes nothing.
  UPDATE public.quiz_answers a
     SET was_correct = EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct),
         points = CASE WHEN EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct)
            THEN 10 ELSE 0 END
   WHERE a.attempt_id = p_attempt_id;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE was_correct), COALESCE(SUM(points),0)
    INTO v_total, v_correct, v_points
    FROM public.quiz_answers WHERE attempt_id = p_attempt_id;

  -- One stats bump per item at finish. Play screens must NOT call
  -- quiz_record_serve, or these double-count.
  UPDATE public.quiz_items qi
     SET times_served  = qi.times_served + 1,
         times_correct = qi.times_correct + CASE WHEN a.was_correct THEN 1 ELSE 0 END,
         updated_at    = now()
    FROM public.quiz_answers a
   WHERE a.attempt_id = p_attempt_id AND qi.id = a.item_id AND qi.agency_id = v_agency;

  UPDATE public.quiz_attempts
     SET finished_at = now(), question_count = v_total,
         correct_count = v_correct, points_earned = v_points, score = v_points
   WHERE id = p_attempt_id;

  -- Sunday-anchored CT week keyed by attempt_day (house convention)
  v_day        := v_att.attempt_day;
  v_dow        := EXTRACT(DOW FROM v_day)::int;
  v_week_start := v_day - v_dow;
  v_week_sat   := v_week_start + 6;
  v_label      := 'Trivia week of ' || to_char(v_week_sat, 'Mon DD, YYYY');

  SELECT COALESCE(SUM(points_earned),0) INTO v_week_pts
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND finished_at IS NOT NULL
     AND attempt_day BETWEEN v_week_start AND v_week_sat;

  IF v_week_pts > 0 THEN
    -- Records board only. record_week_ending stays NULL FOREVER on this
    -- category so comp math can never date-match it (Ruling 20).
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

  RETURN jsonb_build_object('correct_count', v_correct, 'question_count', v_total,
    'points_earned', v_points, 'week_points', v_week_pts, 'on_leaderboard', v_on_board);
END; $$;

-- 1h. Duel plumbing (Ruling 23)
CREATE OR REPLACE FUNCTION public.quiz_duel_opponents()
RETURNS TABLE (team_member_id uuid, first_name text)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT t.id, t.first_name
    FROM public.team t
   WHERE t.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
     AND t.is_active = true AND t.archived_at IS NULL
     AND t.is_admin_backoffice = false AND (t.is_test_user IS NOT TRUE)
     AND t.id <> public.current_team_member_id()
   ORDER BY t.first_name;
$$;

CREATE OR REPLACE FUNCTION public.quiz_pending_duels()
RETURNS TABLE (challenge_attempt_id uuid, challenger_name text, challenged_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT a.id, t.first_name, a.finished_at
    FROM public.quiz_attempts a
    JOIN public.team t ON t.id = a.team_member_id
   WHERE a.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
     AND a.mode_key = 'duel'
     AND a.finished_at IS NOT NULL
     AND a.opponent_attempt_id IS NULL
     AND (a.context->>'duel_opponent_team_member_id')::uuid = public.current_team_member_id()
   ORDER BY a.finished_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.quiz_accept_duel(p_challenge_attempt_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid;
  v_member uuid;
  v_ch     public.quiz_attempts;
  v_new    uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();

  SELECT * INTO v_ch FROM public.quiz_attempts
   WHERE id = p_challenge_attempt_id AND agency_id = v_agency
     AND mode_key = 'duel' AND finished_at IS NOT NULL
     AND opponent_attempt_id IS NULL
     AND (context->>'duel_opponent_team_member_id')::uuid = v_member
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'duel not found, not yours, or already accepted'; END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context, opponent_attempt_id)
  VALUES (v_agency, v_member, 'duel',
          jsonb_build_object('item_ids', v_ch.context->'item_ids',
                             'duel_challenge_of', p_challenge_attempt_id),
          p_challenge_attempt_id)
  RETURNING id INTO v_new;

  UPDATE public.quiz_attempts SET opponent_attempt_id = v_new
   WHERE id = p_challenge_attempt_id;
  RETURN v_new;
END; $$;

CREATE OR REPLACE FUNCTION public.quiz_duel_result(p_attempt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid;
  v_member uuid;
  v_mine   public.quiz_attempts;
  v_other  public.quiz_attempts;
  v_my_nm  text; v_ot_nm text;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();

  SELECT * INTO v_mine FROM public.quiz_attempts
   WHERE id = p_attempt_id AND agency_id = v_agency
     AND team_member_id = v_member AND mode_key = 'duel';
  IF NOT FOUND THEN RAISE EXCEPTION 'attempt not found or not yours'; END IF;

  SELECT * INTO v_other FROM public.quiz_attempts
   WHERE id = v_mine.opponent_attempt_id AND agency_id = v_agency;

  SELECT first_name INTO v_my_nm FROM public.team WHERE id = v_member;
  IF v_other.id IS NOT NULL THEN
    SELECT first_name INTO v_ot_nm FROM public.team WHERE id = v_other.team_member_id;
  END IF;

  RETURN jsonb_build_object(
    'my_name', v_my_nm, 'my_points', v_mine.points_earned,
    'my_finished', v_mine.finished_at IS NOT NULL,
    'opponent_name', v_ot_nm,
    'opponent_points', CASE WHEN v_other.finished_at IS NOT NULL THEN v_other.points_earned END,
    'opponent_finished', COALESCE(v_other.finished_at IS NOT NULL, false),
    'both_finished', v_mine.finished_at IS NOT NULL AND COALESCE(v_other.finished_at IS NOT NULL, false));
END; $$;

-- 1i. Grants: play functions are for logged-in staff only
REVOKE ALL ON FUNCTION public.quiz_finish_attempt(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_duel_opponents() FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_pending_duels() FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_accept_duel(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_duel_result(uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.quiz_finish_attempt(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_duel_opponents() TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_pending_duels() TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_accept_duel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_duel_result(uuid) TO authenticated;
