-- Departure recapture feeds the growth budget.
-- Peter 2026-09-13: the base held back from the team bonus pool when a teammate
-- leaves is money the agency keeps. It funds the next hire's ramp, so it is added
-- back to the growth budget instead of disappearing into general profit.
--
-- Three pieces:
--   1. v_departure_recapture_ytd      - calendar-year recapture per departed teammate
--   2. v_growth_budget_full_ytd       - carries the recapture credit alongside spend
--   3. get_growth_budget_ceiling()    - returns effective_ceiling_annual = ceiling + recapture
--
-- Dollar convention: the pool waterfall subtracts the RAW freed base (it sits inside
-- the /1.08 burden wrap, so the envelope reserves base x 1.08 in total). The growth
-- budget views are all fully loaded (annual_base x 1.08). So the credit carried into
-- the growth budget is recapture x 1.08, and the raw pool figure is exposed beside it
-- so the CPR page and the Financials page reconcile.

CREATE OR REPLACE VIEW public.v_departure_recapture_ytd AS
WITH saturdays AS (
  SELECT d::date AS week_end
  FROM generate_series(
         date_trunc('year', CURRENT_DATE)::date,
         CURRENT_DATE,
         INTERVAL '1 day'
       ) AS d
  WHERE EXTRACT(DOW FROM d) = 6
),
departed AS (
  SELECT
    t.agency_id,
    t.id AS team_member_id,
    (t.first_name || ' ' || t.last_name) AS full_name,
    t.start_date,
    t.end_date,
    CASE
      WHEN t.pay_type = 'SALARY' THEN t.pay_rate
      WHEN t.pay_type = 'HOURLY' THEN t.pay_rate * 40
      ELSE 0
    END AS weekly_design_base,
    LEAST(1.00, GREATEST(0, FLOOR((t.end_date - COALESCE(t.start_date, t.end_date))::numeric / 7.0) / 52.0)) AS tenure_mult_at_departure
  FROM public.team t
  WHERE t.category = 'agency'
    AND t.is_admin_backoffice = false
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.end_date IS NOT NULL
    AND t.end_date >= DATE '2026-08-30'   -- forward-only, same cut-off as the pool waterfall
    AND t.pay_rate IS NOT NULL
    AND public.is_agency_admin()
),
weekly AS (
  SELECT
    d.agency_id,
    d.team_member_id,
    d.full_name,
    d.end_date,
    d.weekly_design_base,
    d.tenure_mult_at_departure,
    s.week_end,
    d.weekly_design_base
      * (1 - public.team_week_base_fraction(d.agency_id, d.team_member_id, d.start_date, d.end_date, s.week_end))
      * d.tenure_mult_at_departure
      * GREATEST(0, 1 - FLOOR((s.week_end - d.end_date)::numeric / 7.0) / 52.0) AS recapture_weekly
  FROM departed d
  JOIN saturdays s ON s.week_end > d.end_date
)
SELECT
  agency_id,
  team_member_id,
  full_name,
  end_date,
  ROUND(SUM(recapture_weekly), 2)          AS recapture_pool_ytd_dollars,
  ROUND(SUM(recapture_weekly) * 1.08, 2)   AS recapture_ytd_dollars,
  COUNT(*) FILTER (WHERE recapture_weekly > 0) AS weeks_recaptured_ytd,
  ROUND((array_agg(recapture_weekly ORDER BY week_end DESC))[1], 2)        AS recapture_pool_weekly_current,
  ROUND((array_agg(recapture_weekly ORDER BY week_end DESC))[1] * 1.08, 2) AS recapture_weekly_current,
  GREATEST(0, 52 - FLOOR((CURRENT_DATE - MAX(end_date))::numeric / 7.0))::int AS weeks_left_in_easedown
FROM weekly
GROUP BY agency_id, team_member_id, full_name, end_date
HAVING SUM(recapture_weekly) > 0
ORDER BY SUM(recapture_weekly) DESC;

COMMENT ON VIEW public.v_departure_recapture_ytd IS
  'Calendar-year dollars held back from the team bonus pool because a teammate left. Same per-week formula the pool waterfall uses (design base x uncovered workdays x tenure_mult at departure, easing straight-line to 0 over 52 weeks). recapture_pool_* matches the CPR page figure; recapture_* is fully loaded (x 1.08) to match the growth budget views.';


CREATE OR REPLACE VIEW public.v_growth_budget_full_ytd AS
WITH salary_totals AS (
  SELECT
    v.agency_id,
    ROUND(SUM(v.growth_budget_ytd), 2) AS salary_ramp_ytd_dollars,
    SUM(v.weeks_ramping_ytd) AS total_weeks_ramping_ytd,
    COUNT(*) AS active_new_hires_ramping
  FROM public.v_growth_budget_ytd v
  GROUP BY v.agency_id
),
licensing_totals AS (
  SELECT
    l.agency_id,
    l.licensing_ytd_dollars,
    l.entry_count AS licensing_entries_ytd
  FROM public.v_growth_budget_licensing_ytd l
),
recapture_totals AS (
  SELECT
    r.agency_id,
    ROUND(SUM(r.recapture_ytd_dollars), 2) AS recapture_ytd_dollars,
    ROUND(SUM(r.recapture_pool_ytd_dollars), 2) AS recapture_pool_ytd_dollars,
    ROUND(SUM(r.recapture_weekly_current), 2) AS recapture_weekly_current,
    COUNT(*) AS departures_recaptured_ytd
  FROM public.v_departure_recapture_ytd r
  GROUP BY r.agency_id
)
SELECT
  COALESCE(s.agency_id, l.agency_id, rc.agency_id) AS agency_id,
  COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) AS salary_ramp_ytd_dollars,
  COALESCE(l.licensing_ytd_dollars, 0::numeric) AS licensing_ytd_dollars,
  (COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) + COALESCE(l.licensing_ytd_dollars, 0::numeric)) AS total_growth_budget_ytd_dollars,
  COALESCE(s.active_new_hires_ramping, 0::bigint) AS active_new_hires_ramping,
  COALESCE(s.total_weeks_ramping_ytd, 0::numeric) AS total_weeks_ramping_ytd,
  COALESCE(l.licensing_entries_ytd, 0::bigint) AS licensing_entries_ytd,
  COALESCE(rc.recapture_ytd_dollars, 0::numeric) AS recapture_ytd_dollars,
  COALESCE(rc.recapture_pool_ytd_dollars, 0::numeric) AS recapture_pool_ytd_dollars,
  COALESCE(rc.recapture_weekly_current, 0::numeric) AS recapture_weekly_current,
  COALESCE(rc.departures_recaptured_ytd, 0::bigint) AS departures_recaptured_ytd
FROM (salary_totals s
  FULL JOIN licensing_totals l ON l.agency_id = s.agency_id)
  FULL JOIN recapture_totals rc ON rc.agency_id = COALESCE(s.agency_id, l.agency_id)
WHERE public.is_agency_admin();


CREATE OR REPLACE FUNCTION public.get_growth_budget_ceiling(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pct numeric;
  v_annual_override numeric;
  v_year int := EXTRACT(YEAR FROM CURRENT_DATE)::int;
  v_max_period_month int;
  v_comp_anchor_date date;
  v_days_elapsed int;
  v_annualization numeric;
  v_ytd_gross_ex_scorecard numeric;
  v_on_time_annual_gross numeric;
  v_scorecard_ytd numeric;
  v_ceiling numeric;
  v_basis text;
  v_recapture numeric := 0;
  v_recapture_pool numeric := 0;
BEGIN
  SELECT
    growth_budget_ceiling_pct_of_gross,
    growth_budget_ceiling_annual
  INTO v_pct, v_annual_override
  FROM public.agency
  WHERE id = p_agency_id;

  -- Anchor annualization on end of latest complete comp_recap period
  SELECT MAX(period_month) INTO v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id AND period_year = v_year;

  IF v_max_period_month IS NULL THEN
    -- No comp data yet this year — fall back to override or NULL
    v_on_time_annual_gross := 0;
    v_ytd_gross_ex_scorecard := 0;
    v_scorecard_ytd := 0;
    v_annualization := NULL;
    v_days_elapsed := NULL;
    v_comp_anchor_date := NULL;
  ELSE
    v_comp_anchor_date := (make_date(v_year, v_max_period_month, 1) + INTERVAL '1 month - 1 day')::date;
    v_days_elapsed := (v_comp_anchor_date - make_date(v_year, 1, 1))::int + 1;
    v_annualization := 365.0 / v_days_elapsed::numeric;

    -- YTD gross earnings excluding scorecard bonus + deductions
    SELECT COALESCE(SUM(amount), 0)
    INTO v_ytd_gross_ex_scorecard
    FROM public.comp_recap
    WHERE agency_id = p_agency_id
      AND period_year = v_year
      AND comp_category NOT LIKE 'deduction_%'
      AND comp_category <> 'reportable_benefit'
      AND NOT (comp_category = 'state_farm_bonuses' AND description ILIKE '%scorecard%');

    -- Scorecard YTD (for reporting only)
    SELECT COALESCE(SUM(amount), 0)
    INTO v_scorecard_ytd
    FROM public.comp_recap
    WHERE agency_id = p_agency_id
      AND period_year = v_year
      AND comp_category = 'state_farm_bonuses'
      AND description ILIKE '%scorecard%';

    v_on_time_annual_gross := v_ytd_gross_ex_scorecard * v_annualization;
  END IF;

  IF v_pct IS NOT NULL AND v_on_time_annual_gross > 0 THEN
    v_ceiling := v_pct * v_on_time_annual_gross;
    v_basis := 'pct_of_on_time_annual_gross_ex_scorecard';
  ELSIF v_annual_override IS NOT NULL THEN
    v_ceiling := v_annual_override;
    v_basis := 'fixed_annual_override';
  ELSE
    v_ceiling := NULL;
    v_basis := 'none';
  END IF;

  -- Departure recapture: base held back from the team bonus pool when a teammate
  -- left is added back to the growth budget (Peter 2026-09-13). Fully loaded to
  -- match the growth budget views; the raw pool figure is returned beside it.
  SELECT
    COALESCE(SUM(r.recapture_ytd_dollars), 0),
    COALESCE(SUM(r.recapture_pool_ytd_dollars), 0)
  INTO v_recapture, v_recapture_pool
  FROM public.v_departure_recapture_ytd r
  WHERE r.agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'ceiling_annual', ROUND(v_ceiling, 2),
    'recapture_ytd_dollars', ROUND(v_recapture, 2),
    'recapture_pool_ytd_dollars', ROUND(v_recapture_pool, 2),
    'effective_ceiling_annual', ROUND(COALESCE(v_ceiling, 0) + v_recapture, 2),
    'pct_of_on_time_annual_gross', v_pct,
    'ytd_gross_ex_scorecard', ROUND(v_ytd_gross_ex_scorecard, 2),
    'on_time_annual_gross', ROUND(v_on_time_annual_gross, 2),
    'scorecard_ytd_excluded', ROUND(v_scorecard_ytd, 2),
    'annualization_factor', ROUND(v_annualization, 5),
    'days_elapsed', v_days_elapsed,
    'comp_anchor_date', v_comp_anchor_date,
    'max_period_month', v_max_period_month,
    'basis', v_basis,
    'computed_at', now()
  );
END;
$function$;
