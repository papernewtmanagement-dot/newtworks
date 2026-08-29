-- Peter 2026-08-28: a week that has been paid reads the payroll number. No
-- recalculation, no drift. Payroll is the record of what happened.
DO $mig$
DECLARE v_src text; v_new text; v_old text; v_rep text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  v_old := '  settled AS (SELECT e.*, GREATEST(0, e.qtd_bonus_earned) AS this_week_bonus, GREATEST(0, e.qtd_sales_share) AS this_week_sales_share, GREATEST(0, e.qtd_retention_share) AS this_week_retention_share FROM earned e),';

  v_rep := '  locked_pay AS (SELECT pd.team_member_id AS tm_id, SUM((kv.value->>''period'')::numeric) AS paid_bonus FROM public.weekly_pool_lock wl JOIN public.payroll_runs pr ON pr.pay_period_end = wl.week_end_date JOIN public.payroll_detail pd ON pd.payroll_run_id = pr.id AND pd.agency_id = p_agency_id CROSS JOIN LATERAL jsonb_each(COALESCE(pd.raw_earnings->''items'', ''{}''::jsonb)) kv WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date AND kv.key ILIKE ''%Team%'' GROUP BY pd.team_member_id),
  settled AS (SELECT e.*, COALESCE(lp.paid_bonus, GREATEST(0, e.qtd_bonus_earned)) AS this_week_bonus, CASE WHEN lp.paid_bonus IS NOT NULL AND (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) > 0 THEN lp.paid_bonus * GREATEST(0, e.qtd_sales_share) / (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) ELSE GREATEST(0, e.qtd_sales_share) END AS this_week_sales_share, CASE WHEN lp.paid_bonus IS NOT NULL AND (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) > 0 THEN lp.paid_bonus * GREATEST(0, e.qtd_retention_share) / (GREATEST(0, e.qtd_sales_share) + GREATEST(0, e.qtd_retention_share)) ELSE GREATEST(0, e.qtd_retention_share) END AS this_week_retention_share FROM earned e LEFT JOIN locked_pay lp ON lp.tm_id = e.tm_id),';

  v_new := replace(v_src, v_old, v_rep);
  IF v_new = v_src THEN RAISE EXCEPTION 'settled CTE anchor not found - function unchanged'; END IF;
  EXECUTE v_new;
END
$mig$;

