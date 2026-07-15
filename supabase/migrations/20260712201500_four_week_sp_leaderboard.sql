-- Peter directive 2026-07-12 pm3: add "4-week sales" leaderboard (rolling 4-week SP sum).
-- Same leaderboard/all-star/trailblazer mechanics as week_sp / week_quotes / quarter_sp.

-- ── 0. Widen CHECK constraints across the 4 tables that pin the category to a fixed list ──
ALTER TABLE public.leaderboard_floor_config DROP CONSTRAINT IF EXISTS leaderboard_floor_config_category_check;
ALTER TABLE public.leaderboard_floor_config
  ADD CONSTRAINT leaderboard_floor_config_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.leaderboards DROP CONSTRAINT IF EXISTS leaderboards_category_check;
ALTER TABLE public.leaderboards
  ADD CONSTRAINT leaderboards_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.all_star_counts DROP CONSTRAINT IF EXISTS all_star_counts_category_check;
ALTER TABLE public.all_star_counts
  ADD CONSTRAINT all_star_counts_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

ALTER TABLE public.trailblazer_crossings DROP CONSTRAINT IF EXISTS trailblazer_crossings_category_check;
ALTER TABLE public.trailblazer_crossings
  ADD CONSTRAINT trailblazer_crossings_category_check
  CHECK (category = ANY (ARRAY['quarter_sp','week_sp','week_quotes','four_week_sp']));

-- ── 1. Floor config ─────────────────────────────────────────────
INSERT INTO public.leaderboard_floor_config (category, round_step, round_direction, description)
VALUES ('four_week_sp', 200, 'floor', 'Rolling 4-week sales points all-star floor = bronze rounded down to nearest 200')
ON CONFLICT (category) DO NOTHING;

-- ── 2. Helper: rolling 4-week SP per person at week W ──────────
-- Formula:
--   Case A — window fully within curr Q (weeks_elapsed_in_Q >= 4):
--     rolling_4wk = QTD(W) - QTD(W-4wks in same Q)
--   Case B — window straddles quarter boundary (weeks_elapsed < 4):
--     rolling_4wk = QTD(W) + (4 - weeks_elapsed) / 13 * prior_Q_total
--
-- QTD(W-4) missing -> treated as 0.
-- Prior Q missing -> contribution 0.
CREATE OR REPLACE FUNCTION public.compute_rolling_4wk_sp(
  p_agency_id uuid,
  p_week_end_date date,
  p_team_member_id uuid
) RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_q_start           date;
  v_weeks_elapsed     int;
  v_curr_qtd          numeric := 0;
  v_qtd_minus_4       numeric := 0;
  v_prior_q_total     numeric := 0;
  v_result            numeric;
BEGIN
  v_q_start := date_trunc('quarter', p_week_end_date::timestamp)::date;
  v_weeks_elapsed := ((p_week_end_date - v_q_start) / 7) + 1;

  SELECT COALESCE(d.sales_points, 0)
    INTO v_curr_qtd
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND d.team_member_id = p_team_member_id
    AND r.week_ending_date = p_week_end_date;

  v_curr_qtd := COALESCE(v_curr_qtd, 0);

  IF v_weeks_elapsed >= 4 THEN
    SELECT COALESCE(d.sales_points, 0)
      INTO v_qtd_minus_4
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND d.team_member_id = p_team_member_id
      AND r.week_ending_date = (p_week_end_date - INTERVAL '28 days')::date
      AND r.week_ending_date >= v_q_start;

    v_qtd_minus_4 := COALESCE(v_qtd_minus_4, 0);
    v_result := GREATEST(0, v_curr_qtd - v_qtd_minus_4);
    RETURN v_result;
  END IF;

  SELECT d.sales_points
    INTO v_prior_q_total
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  WHERE r.agency_id = p_agency_id
    AND d.team_member_id = p_team_member_id
    AND d.sales_points IS NOT NULL
    AND date_trunc('quarter', r.week_ending_date::timestamp)::date < v_q_start
  ORDER BY r.week_ending_date DESC
  LIMIT 1;

  v_prior_q_total := COALESCE(v_prior_q_total, 0);

  v_result := v_curr_qtd + ((4 - v_weeks_elapsed)::numeric / 13.0) * v_prior_q_total;
  RETURN GREATEST(0, v_result);
END;
$$;

-- ── 3. Seed leaderboards (smooth-avg 4-week from historical quarter totals) ──
-- Provisional: quarter_total * 4/13. Walk-based tier-aware peaks would be higher.
INSERT INTO public.leaderboards (agency_id, category, tier, team_member_id, record_value, record_period_label, record_week_ending, set_at, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 1,
    'ea296434-7802-4370-9cb9-f689df722830', 2260.85, 'Q1 2026 (smooth avg)', '2026-03-28', now(),
    'Provisional seed: quarter_total x 4/13'),
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 2,
    'ea296434-7802-4370-9cb9-f689df722830', 1711.38, 'Q4 2025 (smooth avg)', '2025-12-27', now(),
    'Provisional seed: quarter_total x 4/13'),
  ('126794dd-25ff-47d2-a436-724499733365', 'four_week_sp', 3,
    '893c77db-1d39-4870-8433-434d9ba07b84', 1593.61, 'Q2 2026 (smooth avg)', '2026-06-27', now(),
    'Provisional seed: quarter_total x 4/13');

-- ── 4. audit_weekly_leaderboard_crossings: add four_week_sp branch via compute_rolling_4wk_sp helper.
--    Full function body committed with the branch. See supabase/migrations/... for the CREATE OR REPLACE.
-- (Body identical to the running DB — kept short in mirror to avoid duplication churn.
--  Change is: new `WHEN 'four_week_sp' THEN public.compute_rolling_4wk_sp(...)` branch in the CASE.)
