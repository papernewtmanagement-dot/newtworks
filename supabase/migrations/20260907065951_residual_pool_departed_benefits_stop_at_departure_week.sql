-- A departed teammate's agency-paid benefits stop coming out of the pool from the week they
-- leave (Peter 2026-09-07: "current benefits also should not be subtracted any longer"). Prior
-- full weeks stay. Before this the departure week charged the pool the workday fraction of that
-- week's benefit (John: 0.4 x $80.26 = $32.10 on the week ending 2026-09-05).

DO $do$
DECLARE
  v_src text;
BEGIN
  v_src := pg_get_functiondef('public.compute_weekly_comp_residual_pool(uuid, date)'::regprocedure);

  -- per-week benefit fraction: 0 for any week the person's last day falls on or before that Saturday
  v_src := public.fn_source_replace_exact(v_src,
    $q$ AS week_base_paid, public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) AS week_fraction, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),$q$,
    $q$ AS week_base_paid, public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) AS week_fraction, CASE WHEN r.end_date IS NOT NULL AND r.end_date <= cw.week_end_date THEN 0 ELSE public.team_week_workday_fraction(r.start_date, r.end_date, cw.week_end_date) END AS benefit_week_fraction, LEAST(1.00, GREATEST(0, FLOOR((cw.week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS week_tenure_mult FROM roster r CROSS JOIN cycle_weeks cw JOIN per_week_pay pwp ON pwp.tm_id = r.id AND pwp.week_end_date = cw.week_end_date),$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$SUM(week_fraction) AS qtd_weeks_on_team FROM base_by_week GROUP BY tm_id),$q$,
    $q$SUM(week_fraction) AS qtd_weeks_on_team, SUM(benefit_week_fraction) AS qtd_weeks_on_team_benefits FROM base_by_week GROUP BY tm_id),$q$, 1);

  v_src := public.fn_source_replace_exact(v_src,
    $q$CASE WHEN r.in_week THEN r.weekly_health_benefit_agency_paid ELSE 0 END AS weekly_health_benefit_agency_paid, COALESCE(r.weekly_health_benefit_agency_paid, 0) * COALESCE(b.qtd_weeks_on_team, 0) AS c_health_qtd,$q$,
    $q$CASE WHEN r.shares_eligible THEN r.weekly_health_benefit_agency_paid ELSE 0 END AS weekly_health_benefit_agency_paid, COALESCE(r.weekly_health_benefit_agency_paid, 0) * COALESCE(b.qtd_weeks_on_team_benefits, 0) AS c_health_qtd,$q$, 1);

  EXECUTE v_src;
END
$do$;
