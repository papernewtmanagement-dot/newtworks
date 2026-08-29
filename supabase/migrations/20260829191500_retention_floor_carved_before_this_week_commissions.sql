-- The retention minimum is carved BEFORE this week's commissions come out, not after.
--
-- What was wrong: the floor was capped at the bonus pool. The bonus pool is what is
-- left AFTER commissions are subtracted, so in any week where commissions drained the
-- pool the cap knocked the floor straight back to zero — the floor died in exactly the
-- weeks it exists for. The cap is removed entirely. It is not needed: the floor is
-- basis/3 * factor with factor never above 1.00, so it can never exceed its own basis.
--
-- Basis is the pre-commission pool = the pool BEFORE the clamp at zero, plus THIS
-- WEEK'S commissions added back. Using the clamped pool would silently inflate the
-- basis whenever the raw pool is negative, which is precisely when the floor matters.
-- This week's commissions only, never the quarter's (Peter 2026-08-28).
--
-- Consequence, stated plainly: total paid can exceed the weekly bonus pool, because the
-- retention minimum is funded ahead of commissions rather than out of the remainder.
-- Sales takes whatever is left of the pool and is floored at zero.
DO $mig$
DECLARE
  v_def text;
  a_calc  CONSTANT text := 'pwq.qtd_goals_total - tt.qtd_bonus_paid_prior_total) AS qtd_bonus_pool FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),';
  a_floor CONSTANT text := '  pool_floor AS (SELECT pc.*, CASE WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0 ELSE LEAST(pc.qtd_bonus_pool, GREATEST(pc.qtd_bonus_pool / 3.0, (pc.qtd_bonus_pool + COALESCE(pc.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor)) END AS ret_pool_resolved FROM pool_calc pc),';
  a_split CONSTANT text := '  pool_split AS (SELECT pf.*, pf.ret_pool_resolved AS qtd_retention_pool, (pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_13wk_pool, (pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_4wk_pool FROM pool_floor pf),';
  a_raw   CONSTANT text := '        ''retention_floor_raw'', CASE WHEN v_retention_floor_factor IS NULL THEN NULL ELSE ROUND((s.qtd_bonus_pool + COALESCE(s.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor, 2) END,';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN RAISE EXCEPTION 'function not found'; END IF;
  IF position('qtd_bonus_pool_raw' in v_def) > 0 THEN
    RAISE EXCEPTION 'already patched - pre-commission basis is present';
  END IF;

  FOREACH v_def IN ARRAY ARRAY[v_def] LOOP END LOOP;
  n := (length(v_def) - length(replace(v_def, a_calc,  ''))) / length(a_calc);
  IF n <> 1 THEN RAISE EXCEPTION 'pool_calc anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, a_floor, ''))) / length(a_floor);
  IF n <> 1 THEN RAISE EXCEPTION 'pool_floor anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, a_split, ''))) / length(a_split);
  IF n <> 1 THEN RAISE EXCEPTION 'pool_split anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, a_raw,   ''))) / length(a_raw);
  IF n <> 1 THEN RAISE EXCEPTION 'retention_floor_raw anchor matched % times', n; END IF;

  -- expose the UNCLAMPED pool alongside the clamped one
  v_def := replace(v_def, a_calc,
    'pwq.qtd_goals_total - tt.qtd_bonus_paid_prior_total) AS qtd_bonus_pool, ' ||
    '((v_qtd_envelope - v_qtd_wc - (tt.team_weekly_health * v_week_of_cycle)) / (1.0 + v_burden_mult) - tt.qtd_base_in_pool_total - tt.qtd_comm_total - tt.qtd_mgr_total - v_qtd_hdb_max - pwq.qtd_prize_cart - pwq.qtd_wtq_trip - pwq.qtd_goals_total - tt.qtd_bonus_paid_prior_total) AS qtd_bonus_pool_raw ' ||
    'FROM team_totals tt CROSS JOIN prize_wtq_qtd pwq),');

  -- floor off the pre-commission pool, no cap
  v_def := replace(v_def, a_floor,
    '  pool_floor AS (SELECT pc.*, GREATEST(0, pc.qtd_bonus_pool_raw + COALESCE(pc.curr_comm_total, 0)) AS pre_commission_pool, CASE WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0 ELSE GREATEST(pc.qtd_bonus_pool / 3.0, GREATEST(0, pc.qtd_bonus_pool_raw + COALESCE(pc.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor) END AS ret_pool_resolved FROM pool_calc pc),');

  -- sales takes what is left of the pool after the retention slice, floored at zero
  v_def := replace(v_def, a_split,
    '  pool_split AS (SELECT pf.*, pf.ret_pool_resolved AS qtd_retention_pool, GREATEST(0, pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_13wk_pool, GREATEST(0, pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_4wk_pool FROM pool_floor pf),');

  v_def := replace(v_def, a_raw,
    '        ''retention_floor_raw'', CASE WHEN v_retention_floor_factor IS NULL THEN NULL ELSE ROUND(s.pre_commission_pool / 3.0 * v_retention_floor_factor, 2) END,' || chr(10) ||
    '        ''pre_commission_pool'', ROUND(s.pre_commission_pool, 2),' || chr(10) ||
    '        ''qtd_bonus_pool_raw'', ROUND(s.qtd_bonus_pool_raw, 2),');

  EXECUTE v_def;
END
$mig$;
