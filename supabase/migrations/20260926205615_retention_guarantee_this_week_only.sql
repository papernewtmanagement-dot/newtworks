DO $mig$
DECLARE v_src text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='compute_weekly_comp_residual_pool';
  v_src := public.fn_source_replace_exact(v_src,
    E'  rp_qtd AS (SELECT r.id AS tm_id, COALESCE(SUM(CASE WHEN cw.week_end_date = p_week_end_date THEN 0 ELSE COALESCE((SELECT wctd.retention_points_pay FROM public.weekly_cpr_team_detail wctd JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date LIMIT 1), 0) END), 0) AS qtd_rp_prior FROM roster r CROSS JOIN cycle_weeks cw GROUP BY r.id),\n',
    '', 1);
  v_src := public.fn_source_replace_exact(v_src,
    ', COALESCE(rpq.qtd_rp_prior, 0) + CASE WHEN r.shares_eligible THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_qtd_rp FROM roster r LEFT JOIN rp_qtd rpq ON rpq.tm_id = r.id LEFT JOIN base_qtd b',
    ' FROM roster r LEFT JOIN base_qtd b', 1);
  v_src := public.fn_source_replace_exact(v_src, ', SUM(c.c_qtd_rp) AS qtd_rp_total', '', 1);
  v_src := public.fn_source_replace_exact(v_src,
    'CASE WHEN v_points_mode THEN (CASE WHEN ps.qtd_rp_total > 0 THEN c.c_qtd_rp / ps.qtd_rp_total ELSE 0 END)',
    'CASE WHEN v_points_mode THEN (CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END)', 1);
  v_src := public.fn_source_replace_exact(v_src,
    'CASE WHEN v_points_mode THEN c.c_qtd_rp ELSE 0 END AS ret_guarantee,',
    '/* THIS WEEK''s points only (fixed 2026-09-26). The pool is already net of every bonus paid earlier in the cycle, so earlier weeks'' points were paid out of their own weeks; the cycle-to-date guarantee built 2026-09-18 paid them a second time. */ CASE WHEN v_points_mode THEN c.c_net_points ELSE 0 END AS ret_guarantee,', 1);
  v_src := public.fn_source_replace_exact(v_src,
    'GREATEST(0, d.qtd_retention_pool - d.qtd_rp_total)',
    'GREATEST(0, d.qtd_retention_pool - d.rp_total)', 1);
  EXECUTE v_src;
END $mig$;
