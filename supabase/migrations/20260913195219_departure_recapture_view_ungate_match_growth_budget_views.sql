-- Drop the admin gate from the base recapture view so it matches the convention the
-- other growth-budget BASE views already follow (v_growth_budget_ytd and
-- v_growth_budget_current are ungated; only the roll-up v_growth_budget_full_ytd
-- gates on is_agency_admin()). With the gate in place get_growth_budget_ceiling()
-- silently returned zero recapture for any non-admin caller (service role, bots),
-- which would have under-reported the growth budget wherever it is read outside the
-- owner/manager UI.

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
),
weekly AS (
  SELECT
    d.agency_id,
    d.team_member_id,
    d.full_name,
    d.end_date,
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
