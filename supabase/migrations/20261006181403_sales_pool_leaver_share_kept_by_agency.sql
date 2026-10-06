-- Peter 2026-10-06: from week ending 2026-10-10, when a licensed teammate leaves mid-quarter, the agency keeps
-- their share of the two sales-points thirds. They stay in the share math (their 13-week and 4-week averages
-- shrink each week as zeros roll in), but nothing is paid to them and nothing is handed to the rest of the team.
-- What was kept each week is stored once per week on weekly_cpr_reports and taken off later weeks' pool.
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS sales_pool_agency_kept numeric NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.weekly_cpr_reports.sales_pool_agency_kept IS 'Sales-points pool share of teammates who left this quarter, kept by the agency this week. Peter 2026-10-06.';

DO $$
DECLARE v_def text; v_new text;
  r record;
BEGIN
  v_def := pg_get_functiondef('public.compute_weekly_comp_residual_pool(uuid,date)'::regprocedure);
  v_new := v_def;
  FOR r IN SELECT * FROM (VALUES
    (1, $a$  v_recapture_from CONSTANT date := '2026-08-30';  -- departure recapture is forward-only (Peter 2026-09-06)
BEGIN
$a$, $b$  v_recapture_from CONSTANT date := '2026-08-30';  -- departure recapture is forward-only (Peter 2026-09-06)
  c_leaver_kept_from CONSTANT date := '2026-10-10';  -- Peter 2026-10-06: agency keeps a leaver's sales-points share
  v_kept_prior numeric := 0;
BEGIN
$b$),
    (2, $a$  IF v_cycle_start IS NULL THEN RETURN; END IF;
$a$, $b$  IF v_cycle_start IS NULL THEN RETURN; END IF;
  v_kept_prior := COALESCE((SELECT SUM(rr.sales_pool_agency_kept) FROM public.weekly_cpr_reports rr WHERE rr.agency_id = p_agency_id AND rr.week_ending_date >= v_cycle_start AND rr.week_ending_date < p_week_end_date), 0);
$b$),
    (3, $a$CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk,$a$,
        $b$CASE WHEN r.shares_eligible THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_avg_4wk, CASE WHEN p_week_end_date >= c_leaver_kept_from AND r.left_in_week AND r.end_date >= v_cycle_start THEN COALESCE(sr.avg_13wk, 0) ELSE 0 END AS c_kept_13wk, CASE WHEN p_week_end_date >= c_leaver_kept_from AND r.left_in_week AND r.end_date >= v_cycle_start THEN COALESCE(sr.avg_4wk, 0) ELSE 0 END AS c_kept_4wk,$b$),
    (4, $a$SUM(CASE WHEN c.license_pc THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_licensed,$a$,
        $b$SUM(CASE WHEN c.license_pc THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_licensed, SUM(CASE WHEN c.license_pc THEN c.c_kept_13wk ELSE 0 END) AS kept_avg_13wk_licensed, SUM(CASE WHEN c.license_pc THEN c.c_kept_4wk ELSE 0 END) AS kept_avg_4wk_licensed,$b$),
    (5, $a$- tt.qtd_bonus_paid_prior_total) AS pre_reserve_pool_raw$a$,
        $b$- tt.qtd_bonus_paid_prior_total - v_kept_prior) AS pre_reserve_pool_raw$b$),
    (6, $a$CASE WHEN c.license_pc AND ps.team_avg_13wk_licensed > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_licensed ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_4wk_licensed > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_licensed ELSE 0 END AS sp4_share_ratio FROM combined c CROSS JOIN pool_split ps)$a$,
        $b$CASE WHEN c.license_pc AND (ps.team_avg_13wk_licensed + ps.kept_avg_13wk_licensed) > 0 THEN c.c_avg_13wk / (ps.team_avg_13wk_licensed + ps.kept_avg_13wk_licensed) ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND (ps.team_avg_4wk_licensed + ps.kept_avg_4wk_licensed) > 0 THEN c.c_avg_4wk / (ps.team_avg_4wk_licensed + ps.kept_avg_4wk_licensed) ELSE 0 END AS sp4_share_ratio, CASE WHEN (ps.team_avg_13wk_licensed + ps.kept_avg_13wk_licensed) > 0 THEN ps.kept_avg_13wk_licensed / (ps.team_avg_13wk_licensed + ps.kept_avg_13wk_licensed) ELSE 0 END AS kept13_ratio, CASE WHEN (ps.team_avg_4wk_licensed + ps.kept_avg_4wk_licensed) > 0 THEN ps.kept_avg_4wk_licensed / (ps.team_avg_4wk_licensed + ps.kept_avg_4wk_licensed) ELSE 0 END AS kept4_ratio FROM combined c CROSS JOIN pool_split ps)$b$),
    (7, $a$d.qtd_ret_earned AS qtd_retention_share FROM ret_calc d)$a$,
        $b$d.qtd_ret_earned AS qtd_retention_share, (d.kept13_ratio * d.qtd_sp_13wk_pool + d.kept4_ratio * d.qtd_sp_4wk_pool) AS qtd_agency_kept FROM ret_calc d)$b$),
    (8, $a$'departed_this_week', s.left_in_week, 'shares_eligible', s.shares_eligible,$a$,
        $b$'departed_this_week', s.left_in_week, 'shares_eligible', s.shares_eligible, 'sales_pool_agency_kept_this_week', ROUND(s.qtd_agency_kept, 2), 'sales_pool_agency_kept_prior_qtd', ROUND(v_kept_prior, 2),$b$)
  ) AS t(n, old_s, new_s) LOOP
    IF (length(v_new) - length(replace(v_new, r.old_s, ''))) / length(r.old_s) <> 1 THEN
      RAISE EXCEPTION 'residual pool edit % did not match exactly once', r.n;
    END IF;
    v_new := replace(v_new, r.old_s, r.new_s);
  END LOOP;
  EXECUTE v_new;

  -- Writer: store this week's kept amount once, at week level.
  v_def := pg_get_functiondef('public.write_weekly_comp_v2(uuid,date)'::regprocedure);
  v_new := replace(v_def,
$a$    INTO v_pool_cumulative
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;
$a$,
$b$    INTO v_pool_cumulative
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;
  -- Peter 2026-10-06: a leaver's sales-points share kept by the agency, stored once per week
  UPDATE public.weekly_cpr_reports wr
     SET sales_pool_agency_kept = COALESCE((SELECT MAX(NULLIF(d.residual_pool_diag->>'sales_pool_agency_kept_this_week','')::numeric)
                                              FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report_id), 0)
   WHERE wr.id = v_report_id;
$b$);
  IF v_new = v_def OR (length(v_new) - length(v_def)) < 100 THEN RAISE EXCEPTION 'writer anchor not found'; END IF;
  IF (length(v_def) - length(replace(v_def, $a$  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;
$a$, ''))) / length($a$  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;
$a$) <> 1 THEN RAISE EXCEPTION 'writer anchor not unique'; END IF;
  EXECUTE v_new;
END $$;

