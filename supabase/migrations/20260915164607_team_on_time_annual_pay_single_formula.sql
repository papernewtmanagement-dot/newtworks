-- On-time annual pay for a teammate: the ONE definition.
--
-- This is the formula the weekly CPR has always shown in its OT Annual row,
-- lifted out of the page and into the database so the CPR and the dashboard
-- Earnings chart cannot drift apart. The Earnings chart previously carried a
-- second, thinner version of this sum; that one is gone.
--
--   on-time annual = (payroll YTD paid + this week's pay components)
--                    x 365 / days employed this calendar year
--                    + annual benefits
--
-- Notes that make the two agree exactly:
--  * This week's components are the same eight lines the CPR totals: base,
--    commission, the team bonus net of retention points, retention points,
--    marketing, goals, health goal, manager.
--  * Benefits are flat-added at the end, never annualized, so they do not
--    compound.
--  * Days are counted from January 1, or from the person's start date when
--    they began part way through the year.
--  * Someone whose last day falls on or before the week ending date carries no
--    benefits, matching the CPR.
--
-- SECURITY INVOKER on purpose: it reads only rows the caller can already read,
-- so it cannot widen who sees pay.
CREATE OR REPLACE FUNCTION public.team_on_time_annual_pay(
  p_agency_id uuid,
  p_week_ending_date date DEFAULT NULL
)
RETURNS TABLE (
  team_member_id          uuid,
  week_ending_date        date,
  week_components         numeric,
  weekly_benefits         numeric,
  week_total              numeric,
  ytd_paid                numeric,
  days_employed_this_year integer,
  annual_benefits         numeric,
  on_time_annual          numeric
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH wk AS (
    SELECT COALESCE(
             p_week_ending_date,
             (SELECT MAX(r2.week_ending_date)
                FROM public.weekly_cpr_reports r2
                JOIN public.weekly_cpr_team_detail d2
                  ON d2.weekly_cpr_report_id = r2.id
               WHERE r2.agency_id = p_agency_id
                 AND d2.payroll_ytd_paid IS NOT NULL)
           ) AS week_end
  )
  SELECT
    d.team_member_id,
    r.week_ending_date,
    ROUND(c.week_components, 2),
    ROUND(c.weekly_benefits, 2),
    ROUND(c.week_components + c.weekly_benefits, 2),
    d.payroll_ytd_paid,
    c.days_emp,
    ROUND(c.annual_benefits, 2),
    CASE WHEN d.payroll_ytd_paid IS NULL THEN NULL
         ELSE ROUND(((d.payroll_ytd_paid + c.week_components) * 365.0) / c.days_emp
                    + c.annual_benefits, 2) END
  FROM wk
  JOIN public.weekly_cpr_reports r
    ON r.agency_id = p_agency_id AND r.week_ending_date = wk.week_end
  JOIN public.weekly_cpr_team_detail d
    ON d.weekly_cpr_report_id = r.id
  LEFT JOIN public.team t ON t.id = d.team_member_id
  CROSS JOIN LATERAL (
    SELECT
      COALESCE(d.base_salary, 0)
        + COALESCE(d.commission, 0)
        + (COALESCE(d.bonus, 0) - COALESCE(d.retention_points_pay, 0))
        + COALESCE(d.retention_points_pay, 0)
        + COALESCE(d.marketing_pool_earned_weekly, 0)
        + COALESCE(d.goals_bonus, 0)
        + COALESCE(d.health_bonus, 0)
        + COALESCE(d.manager_bonus, 0)                       AS week_components,
      CASE WHEN d.end_date IS NOT NULL AND d.end_date <= r.week_ending_date
           THEN 0 ELSE COALESCE(t.annual_benefits_value, 0) END        AS annual_benefits,
      CASE WHEN d.end_date IS NOT NULL AND d.end_date <= r.week_ending_date
           THEN 0 ELSE COALESCE(t.annual_benefits_value, 0) / 52.0 END AS weekly_benefits,
      GREATEST(1,
        (r.week_ending_date - GREATEST(
           date_trunc('year', r.week_ending_date)::date,
           COALESCE(d.start_date, d.hire_date, t.hire_date,
                    date_trunc('year', r.week_ending_date)::date)
         ))::int + 1)                                        AS days_emp
  ) c;
$function$;

GRANT EXECUTE ON FUNCTION public.team_on_time_annual_pay(uuid, date) TO authenticated;
