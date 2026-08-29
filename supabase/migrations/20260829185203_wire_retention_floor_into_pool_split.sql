-- Retention floor wired into the three-way pool split.
-- Peter 2026-08-28: retention is guaranteed at least
--   (bonus pool + THIS WEEK'S team commissions) / 3 * retention_floor_factor,
-- capped at the whole pool, never less than its normal third.
-- Factor comes from compute_retention_floor_factor (0.50 = territory median).
-- NULL factor (no territory median entered) => floor is inert, plain thirds.
-- Leftover after the retention slice splits evenly across the two sales thirds.
DO $mig$
DECLARE
  v_def text;
  a_declare   CONSTANT text := 'v_weekly_trailblazer_bonus numeric; v_weekly_goals_total numeric;';
  a_assign    CONSTANT text := 'v_qtd_wc := (v_wc_annual / 52.0) * v_week_of_cycle;';
  a_totals    CONSTANT text := 'SUM(c.c_weighted_hours) AS wh_total,';
  a_split     CONSTANT text := '  pool_split AS (SELECT pc.*, pc.qtd_bonus_pool / 3.0 AS qtd_retention_pool, pc.qtd_bonus_pool / 3.0 AS qtd_sp_13wk_pool, pc.qtd_bonus_pool / 3.0 AS qtd_sp_4wk_pool FROM pool_calc pc),';
  a_diag      CONSTANT text := '''split_thirds'', true' || chr(10);
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found';
  END IF;

  IF position('v_retention_floor_factor' in v_def) > 0 THEN
    RAISE EXCEPTION 'already patched - retention floor is present; refusing to double-apply';
  END IF;

  -- every anchor must appear exactly once, or we abort before touching anything
  FOREACH v_def IN ARRAY ARRAY[v_def] LOOP END LOOP; -- no-op, keeps v_def in scope

  n := (length(v_def) - length(replace(v_def, a_declare, ''))) / length(a_declare);
  IF n <> 1 THEN RAISE EXCEPTION 'declare anchor matched % times, expected 1', n; END IF;

  n := (length(v_def) - length(replace(v_def, a_assign, ''))) / length(a_assign);
  IF n <> 1 THEN RAISE EXCEPTION 'assign anchor matched % times, expected 1', n; END IF;

  n := (length(v_def) - length(replace(v_def, a_totals, ''))) / length(a_totals);
  IF n <> 1 THEN RAISE EXCEPTION 'team_totals anchor matched % times, expected 1', n; END IF;

  n := (length(v_def) - length(replace(v_def, a_split, ''))) / length(a_split);
  IF n <> 1 THEN RAISE EXCEPTION 'pool_split anchor matched % times, expected 1', n; END IF;

  n := (length(v_def) - length(replace(v_def, a_diag, ''))) / length(a_diag);
  IF n <> 1 THEN RAISE EXCEPTION 'diagnostics anchor matched % times, expected 1', n; END IF;

  -- 1. declare the factor
  v_def := replace(v_def, a_declare,
    a_declare || chr(10) || '  v_retention_floor_factor numeric;');

  -- 2. resolve the factor once per call
  v_def := replace(v_def, a_assign,
    a_assign || chr(10) ||
    '  v_retention_floor_factor := NULLIF(public.compute_retention_floor_factor(p_agency_id, p_week_end_date)->>''factor'','''')::numeric;');

  -- 3. team-wide this-week commission total, the floor basis
  v_def := replace(v_def, a_totals,
    'SUM(c.c_curr_comm) AS curr_comm_total, ' || a_totals);

  -- 4. the floor itself, then the split off the remainder
  v_def := replace(v_def, a_split,
    '  pool_floor AS (SELECT pc.*, CASE WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0 ELSE LEAST(pc.qtd_bonus_pool, GREATEST(pc.qtd_bonus_pool / 3.0, (pc.qtd_bonus_pool + COALESCE(pc.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor)) END AS ret_pool_resolved FROM pool_calc pc),' || chr(10) ||
    '  pool_split AS (SELECT pf.*, pf.ret_pool_resolved AS qtd_retention_pool, (pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_13wk_pool, (pf.qtd_bonus_pool - pf.ret_pool_resolved) / 2.0 AS qtd_sp_4wk_pool FROM pool_floor pf),');

  -- 5. make the floor visible in diagnostics
  v_def := replace(v_def, a_diag,
    '''split_thirds'', true,' || chr(10) ||
    '        ''retention_floor_factor'', s.qtd_bonus_pool * 0 + v_retention_floor_factor,' || chr(10) ||
    '        ''retention_floor_basis_commissions'', ROUND(COALESCE(s.curr_comm_total, 0), 2),' || chr(10) ||
    '        ''retention_floor_applied'', (v_retention_floor_factor IS NOT NULL AND s.qtd_retention_pool > (s.qtd_bonus_pool / 3.0) + 0.005)' || chr(10));

  EXECUTE v_def;
END
$mig$;
