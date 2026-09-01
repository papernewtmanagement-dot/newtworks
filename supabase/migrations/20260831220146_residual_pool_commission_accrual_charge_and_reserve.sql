-- Phase 2 step 1: wire the commission accrual charge and the holdback reserve
-- into the team bonus pool waterfall inside compute_weekly_comp_residual_pool.
--
-- Gated on applies_to_pool, which is cycle_start >= 2026-10-04. Q3 2026 and every
-- earlier quarter take the ELSE branch and come out bit-for-bit unchanged.
--
-- Charge: the actual quarter-to-date commission total is replaced by the even-spread
-- accrual charge (projected quarter x week / 13).
--
-- Reserve: reserve_rate x cumulative bonus earned this quarter x (1 - week / 13).
-- Cumulative bonus earned = bonus already paid in prior weeks of the quarter plus
-- the pool available this week. That is the only reading of "cumulative pool earned
-- QTD" the function can compute from its own numbers, and it matches the shipped
-- intent in migration 20260831161301: "always a fraction of what has actually been
-- earned, so it can never exceed the pool."
--
-- The Q3 backfill in commission_projection_log does NOT reproduce from current data
-- under this or any other reading tested (running total of the pool, running total of
-- bonus earned, running total of bonus paid through payroll, prior paid plus this
-- week's pool). Q3 is gated out of the pool, so the backfill is calibration history
-- only and never touches pay.
--
-- Edit is done by splicing the pool_calc block rather than retyping the whole 39k
-- function body. Every anchor is checked for exactly one match and the migration
-- aborts if any check fails.

DO $mig$
DECLARE
  d text;
  a_decl  CONSTANT text := E'  v_points_mode boolean;\nBEGIN\n';
  a_init  CONSTANT text := E'  IF v_cycle_start IS NULL THEN RETURN; END IF;\n';
  a_start CONSTANT text := '  pool_calc AS (SELECT tt.*, pwq.*, v_qtd_envelope AS qtd_envelope,';
  a_end   CONSTANT text := 'FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),';
  p_start int; p_end int;
  new_block CONSTANT text :=
'  pool_calc_pre AS (SELECT tt.*, pwq.*, v_qtd_envelope AS qtd_envelope, v_qtd_wc AS qtd_wc, tt.team_weekly_health * v_week_of_cycle AS qtd_health_total, ((v_qtd_envelope - v_qtd_wc - (tt.team_weekly_health * v_week_of_cycle)) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END) - tt.qtd_mgr_total - v_qtd_hdb_max - pwq.qtd_prize_cart - pwq.qtd_wtq_trip - pwq.qtd_goals_total - tt.qtd_bonus_paid_prior_total) AS pre_reserve_pool_raw FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),
  pool_calc AS (SELECT pcp.*, (CASE WHEN v_accrual_applies THEN GREATEST(0, v_reserve_rate * (pcp.qtd_bonus_paid_prior_total + GREATEST(0, pcp.pre_reserve_pool_raw)) * v_reserve_decay) ELSE 0 END) AS qtd_reserve_held, GREATEST(0, GREATEST(0, pcp.pre_reserve_pool_raw) - (CASE WHEN v_accrual_applies THEN GREATEST(0, v_reserve_rate * (pcp.qtd_bonus_paid_prior_total + GREATEST(0, pcp.pre_reserve_pool_raw)) * v_reserve_decay) ELSE 0 END)) AS qtd_bonus_pool, pcp.pre_reserve_pool_raw AS qtd_bonus_pool_raw FROM pool_calc_pre pcp),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF d IS NULL THEN RAISE EXCEPTION 'function not found'; END IF;
  IF position('pool_calc_pre' in d) > 0 THEN RAISE EXCEPTION 'already patched'; END IF;
  IF (length(d) - length(replace(d, a_decl,  ''))) / length(a_decl)  <> 1 THEN RAISE EXCEPTION 'decl anchor not unique';  END IF;
  IF (length(d) - length(replace(d, a_init,  ''))) / length(a_init)  <> 1 THEN RAISE EXCEPTION 'init anchor not unique';  END IF;
  IF (length(d) - length(replace(d, a_start, ''))) / length(a_start) <> 1 THEN RAISE EXCEPTION 'start anchor not unique'; END IF;
  IF (length(d) - length(replace(d, a_end,   ''))) / length(a_end)   <> 1 THEN RAISE EXCEPTION 'end anchor not unique';   END IF;

  d := replace(d, a_decl,
    E'  v_points_mode boolean;\n'
    || E'  v_accrual jsonb; v_accrual_applies boolean; v_comm_charge numeric;\n'
    || E'  v_reserve_rate CONSTANT numeric := 0.30; v_reserve_decay numeric;\n'
    || E'BEGIN\n');

  d := replace(d, a_init,
    a_init
    || E'  v_accrual := public.compute_commission_accrual(p_agency_id, p_week_end_date);\n'
    || E'  v_accrual_applies := COALESCE((v_accrual->>''applies_to_pool'')::boolean, false);\n'
    || E'  v_comm_charge := COALESCE(NULLIF(v_accrual->>''accrual_charge_qtd'','''')::numeric, 0);\n'
    || E'  v_reserve_decay := GREATEST(0, 1.0 - (v_week_of_cycle::numeric / v_weeks_in_cycle::numeric));\n');

  p_start := position(a_start in d);
  p_end   := position(a_end in d) + length(a_end) - 1;
  IF p_end <= p_start THEN RAISE EXCEPTION 'anchor order wrong'; END IF;

  d := left(d, p_start - 1) || new_block || substring(d from p_end + 1);

  EXECUTE d;
END
$mig$;
