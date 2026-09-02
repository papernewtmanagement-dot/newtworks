-- Phase 2 step 2. The weekly writer now records the commission projection and the
-- holdback reserve every run, so commission_projection_log fills itself instead of
-- being backfilled by hand.
--
-- The reserve needs the cumulative bonus earned so far this quarter. That is taken
-- from the pool function's own diagnostics: bonus already paid in prior weeks of the
-- quarter, plus the pool available this week. Same reading used inside the pool
-- waterfall in migration residual_pool_commission_accrual_charge_and_reserve.
--
-- Result is added to the writer's return value under commission_projection_result.

DO $mig$
DECLARE
  d text;
  a_decl CONSTANT text := E'  v_wtw_adj_rows   int := 0;\n';
  a_ret  CONSTANT text := E'    ''prefill_result'', v_prefill_result,\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'write_weekly_comp_v2';

  IF d IS NULL THEN RAISE EXCEPTION 'writer not found'; END IF;
  IF position('v_comm_proj_result' in d) > 0 THEN RAISE EXCEPTION 'already patched'; END IF;
  IF (length(d) - length(replace(d, a_decl, ''))) / length(a_decl) <> 1 THEN RAISE EXCEPTION 'decl anchor not unique'; END IF;
  IF (length(d) - length(replace(d, a_ret,  ''))) / length(a_ret)  <> 1 THEN RAISE EXCEPTION 'return anchor not unique'; END IF;

  d := replace(d, a_decl,
    a_decl
    || E'  v_comm_proj_result jsonb;\n'
    || E'  v_pool_cumulative  numeric;\n');

  d := replace(d, a_ret,
    E'    ''commission_projection_result'', v_comm_proj_result,\n' || a_ret);

  d := replace(d, E'  RETURN jsonb_build_object(''agency_id'', p_agency_id, ''week_end_date'', p_week_end_date, ''weekly_cpr_report_id'', v_report_id,',
    E'  SELECT MAX((r.diagnostics->''qtd_subtractions''->>''qtd_bonus_paid_prior'')::numeric)\n'
    || E'         + MAX((r.diagnostics->''qtd_pools''->>''qtd_bonus_pool'')::numeric)\n'
    || E'    INTO v_pool_cumulative\n'
    || E'  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) r;\n\n'
    || E'  v_comm_proj_result := public.write_commission_projection(p_agency_id, p_week_end_date, v_pool_cumulative);\n\n'
    || E'  RETURN jsonb_build_object(''agency_id'', p_agency_id, ''week_end_date'', p_week_end_date, ''weekly_cpr_report_id'', v_report_id,');

  EXECUTE d;
END
$mig$;
