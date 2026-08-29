-- Carry the whole retention-floor working into the pool diagnostics so the
-- CPR "Formula — Team Pool build" expander can show the breakout: territory
-- medians, our own lapse rates, the two ratios, the blended ratio, the raw
-- floor, and the normal third it is measured against.
DO $mig$
DECLARE
  v_def text;
  a_declare CONSTANT text := '  v_retention_floor_factor numeric;';
  a_assign  CONSTANT text := '  v_retention_floor_factor := NULLIF(public.compute_retention_floor_factor(p_agency_id, p_week_end_date)->>''factor'','''')::numeric;';
  a_diag    CONSTANT text := '        ''retention_floor_applied'', (v_retention_floor_factor IS NOT NULL AND s.qtd_retention_pool > (s.qtd_bonus_pool / 3.0) + 0.005)';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found'; END IF;
  IF position('v_retention_floor_diag' in v_def) > 0 THEN
    RAISE EXCEPTION 'already patched - floor detail is present';
  END IF;

  n := (length(v_def) - length(replace(v_def, a_declare, ''))) / length(a_declare);
  IF n <> 1 THEN RAISE EXCEPTION 'declare anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, a_assign, ''))) / length(a_assign);
  IF n <> 1 THEN RAISE EXCEPTION 'assign anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, a_diag, ''))) / length(a_diag);
  IF n <> 1 THEN RAISE EXCEPTION 'diag anchor matched % times', n; END IF;

  v_def := replace(v_def, a_declare, a_declare || chr(10) || '  v_retention_floor_diag jsonb;');

  v_def := replace(v_def, a_assign,
    '  v_retention_floor_diag := public.compute_retention_floor_factor(p_agency_id, p_week_end_date);' || chr(10) ||
    '  v_retention_floor_factor := NULLIF(v_retention_floor_diag->>''factor'','''')::numeric;');

  v_def := replace(v_def, a_diag,
    a_diag || ',' || chr(10) ||
    '        ''retention_floor_detail'', v_retention_floor_diag,' || chr(10) ||
    '        ''retention_floor_raw'', CASE WHEN v_retention_floor_factor IS NULL THEN NULL ELSE ROUND((s.qtd_bonus_pool + COALESCE(s.curr_comm_total, 0)) / 3.0 * v_retention_floor_factor, 2) END,' || chr(10) ||
    '        ''retention_normal_third'', ROUND(s.qtd_bonus_pool / 3.0, 2)');

  EXECUTE v_def;
END
$mig$;
