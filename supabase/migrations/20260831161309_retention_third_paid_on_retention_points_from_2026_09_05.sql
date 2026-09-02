-- Retention third of the team bonus pool: paid on Retention Points from week ending 2026-09-05.
--
-- Handbook "Retention Points" > What You Get Paid:
--   1. Your points, as dollars, on that week's check. Guaranteed — if the retention third comes up
--      short, the agency covers the difference.
--   2. Pool share: whatever is left in the retention third after everyone's points are paid, split by
--      each person's share of the team's points.
--
-- Mechanics (compute_weekly_comp_residual_pool):
--   points mode (week_end >= go-live):
--     retention $ = net_points (1 point = $1, guaranteed)
--                 + points_share × max(0, retention_third − team_net_points)
--     agency top-up = max(0, net_points − points_share × retention_third)   [the part the third could not fund]
--     Sales thirds untouched: they still take what is left of the pool after the retention slice.
--   hours mode (weeks before go-live): unchanged — weighted-hours share of the third.
--   The agency top-up is stored per person (weekly_cpr_team_detail.retention_guarantee_topup) and is
--   SUBTRACTED from "prior bonus paid" in later weeks, so the guarantee never claws back from the
--   team's future pool. That is what "the agency covers the difference" means in the math.
--
-- Go-live week: week ending Saturday 2026-09-05 — the first week the team can log as they go
-- (Activity Log shipped 2026-08-31; Peter 2026-08-26: no trial period, live as soon as built).
-- Week ending 2026-08-29 still pays on hours, as the handbook said at the time.
--
-- compute_warning_trigger keeps reading weighted_hours_at_40 (cost-coverage attribution, a different
-- purpose); those columns stay in the output unchanged.

-- ---------------------------------------------------------------------------
-- 1. Column for the agency-covered shortfall
-- ---------------------------------------------------------------------------
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS retention_guarantee_topup numeric NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.weekly_cpr_team_detail.retention_guarantee_topup IS
  'Retention Points guarantee the retention third could not fund this week; agency-covered, excluded from later weeks'' prior-paid subtraction in compute_weekly_comp_residual_pool.';

-- ---------------------------------------------------------------------------
-- 2. compute_weekly_comp_residual_pool — anchored in-place patch (DROP + CREATE: new output columns)
-- ---------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def text;
  n int;
  a_ret   CONSTANT text := $x$retention_hours_share_pct numeric, person_share_pct numeric,$x$;
  a_decl  CONSTANT text := $x$  v_retention_floor_diag jsonb;$x$;
  a_begin CONSTANT text := $x$  v_retention_floor_factor := NULLIF(v_retention_floor_diag->>'factor','')::numeric;$x$;
  a_paid  CONSTANT text := $x$      ) AS week_bonus_paid$x$;
  a_whf   CONSTANT text := $x$  wh_final AS (SELECT tm_id, baseline_hours * retention_weight_role * retention_weight_location * retention_weight_tenure * retention_weight_license AS weighted_hours, retention_weight_role, retention_weight_location, retention_weight_tenure, retention_weight_license FROM wh_calc),$x$;
  a_comb1 CONSTANT text := $x$COALESCE(wf.weighted_hours, 0) AS c_weighted_hours, wf.retention_weight_role,$x$;
  a_comb2 CONSTANT text := $x$LEFT JOIN wh_final wf ON wf.tm_id = r.id),$x$;
  a_tt    CONSTANT text := $x$SUM(c.c_weighted_hours) AS wh_total,$x$;
  a_dist  CONSTANT text := $x$  distributed AS (SELECT c.*, ps.*, CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS ret_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_13wk_licensed > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_licensed ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_4wk_licensed > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_licensed ELSE 0 END AS sp4_share_ratio FROM combined c CROSS JOIN pool_split ps),$x$;
  a_earn  CONSTANT text := $x$  earned AS (SELECT d.*, d.ret_share_ratio * d.qtd_retention_pool AS qtd_ret_earned, d.sp13_share_ratio * d.qtd_sp_13wk_pool AS qtd_sp13_earned, d.sp4_share_ratio * d.qtd_sp_4wk_pool AS qtd_sp4_earned, (d.ret_share_ratio * d.qtd_retention_pool + d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_bonus_earned, (d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_sales_share, (d.ret_share_ratio * d.qtd_retention_pool) AS qtd_retention_share FROM distributed d),$x$;
  a_out   CONSTANT text := $x$    ROUND(s.c_weighted_hours, 4) AS weighted_hours_at_40, ROUND(s.ret_share_ratio * 100, 4) AS retention_hours_share_pct,$x$;
  a_wf    CONSTANT text := $x$      'weight_factors', jsonb_build_object('hours_baseline', 40.0, 'role_w', s.retention_weight_role, 'location_w', s.retention_weight_location, 'tenure_w', s.retention_weight_tenure, 'license_w', s.retention_weight_license),$x$;
  a_qrp   CONSTANT text := $x$        'qtd_retention_pool', ROUND(s.qtd_retention_pool, 2),$x$;
  anchors text[];
  a text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';
  IF v_def IS NULL THEN RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found'; END IF;
  IF position('v_points_mode' in v_def) > 0 THEN RAISE EXCEPTION 'already patched - v_points_mode present'; END IF;

  anchors := ARRAY[a_ret, a_decl, a_begin, a_paid, a_whf, a_comb1, a_comb2, a_tt, a_dist, a_earn, a_out, a_wf, a_qrp];
  FOREACH a IN ARRAY anchors LOOP
    n := (length(v_def) - length(replace(v_def, a, ''))) / length(a);
    IF n <> 1 THEN RAISE EXCEPTION 'anchor matched % times: %', n, left(a, 80); END IF;
  END LOOP;

  -- output columns
  v_def := replace(v_def, a_ret,
    $r$retention_hours_share_pct numeric, retention_net_points numeric, retention_points_share_pct numeric, weekly_retention_guarantee numeric, weekly_retention_topup numeric, person_share_pct numeric,$r$);

  -- declarations
  v_def := replace(v_def, a_decl, a_decl || chr(10) ||
    $r$  v_rp_go_live CONSTANT date := DATE '2026-09-05';  -- first week-ending Saturday paid on Retention Points (Peter 2026-08-26: no trial period, live when built; Activity Log shipped 2026-08-31)
  v_points_mode boolean;$r$);

  v_def := replace(v_def, a_begin, a_begin || chr(10) ||
    $r$  v_points_mode := (p_week_end_date >= v_rp_go_live);$r$);

  -- prior weeks' agency top-ups are not the pool's cost: take them back out of "prior bonus paid"
  v_def := replace(v_def, a_paid,
    $r$      ) - COALESCE((SELECT wctd2.retention_guarantee_topup FROM public.weekly_cpr_team_detail wctd2 JOIN public.weekly_cpr_reports wr2 ON wr2.id = wctd2.weekly_cpr_report_id WHERE wr2.agency_id = p_agency_id AND wctd2.team_member_id = r.id AND wr2.week_ending_date = cw.week_end_date LIMIT 1), 0) AS week_bonus_paid$r$);

  -- retention points per person for the week
  v_def := replace(v_def, a_whf, a_whf || chr(10) ||
    $r$  retention_pts AS (SELECT x.team_member_id AS tm_id, COALESCE(x.net_points, 0) AS net_points, COALESCE(x.gross_points, 0) AS gross_points, COALESCE(x.missed_pct, 0) AS missed_pct, COALESCE(x.reduction_pct, 0) AS reduction_pct FROM public.compute_weekly_retention_points(p_agency_id, p_week_end_date) x),$r$);

  v_def := replace(v_def, a_comb1,
    $r$COALESCE(rpx.net_points, 0) AS c_net_points, COALESCE(rpx.gross_points, 0) AS c_gross_points, COALESCE(rpx.missed_pct, 0) AS c_missed_pct, COALESCE(rpx.reduction_pct, 0) AS c_reduction_pct, $r$ || a_comb1);
  v_def := replace(v_def, a_comb2,
    $r$LEFT JOIN wh_final wf ON wf.tm_id = r.id LEFT JOIN retention_pts rpx ON rpx.tm_id = r.id),$r$);

  v_def := replace(v_def, a_tt, a_tt || $r$ SUM(c.c_net_points) AS rp_total,$r$);

  -- share ratios: hours share and points share both computed; the live one picks by mode
  v_def := replace(v_def, a_dist,
    $r$  distributed AS (SELECT c.*, ps.*,
    CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END AS hours_share_ratio,
    CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END AS points_share_ratio,
    CASE WHEN v_points_mode THEN (CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END) ELSE (CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END) END AS ret_share_ratio,
    CASE WHEN v_points_mode THEN c.c_net_points ELSE 0 END AS ret_guarantee,
    CASE WHEN c.license_pc AND ps.team_avg_13wk_licensed > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_licensed ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_4wk_licensed > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_licensed ELSE 0 END AS sp4_share_ratio FROM combined c CROSS JOIN pool_split ps),$r$);

  -- retention earned: points mode = guarantee + share of what is left; hours mode = share of the third
  v_def := replace(v_def, a_earn,
    $r$  ret_calc AS (SELECT d.*,
    /* points mode: every net point is a dollar, guaranteed; whatever is left of the retention third after all point dollars is split by points share (equivalent to GREATEST(guarantee, share × third)). hours mode: weighted-hours share of the third. */
    CASE WHEN v_points_mode THEN d.ret_guarantee + d.ret_share_ratio * GREATEST(0, d.qtd_retention_pool - d.rp_total) ELSE d.ret_share_ratio * d.qtd_retention_pool END AS qtd_ret_earned,
    /* the part of the guarantee the third could not fund; agency-covered, never clawed back from the later pool (see bonus_paid_by_week) */
    CASE WHEN v_points_mode THEN GREATEST(0, d.ret_guarantee - d.ret_share_ratio * d.qtd_retention_pool) ELSE 0 END AS qtd_ret_topup
    FROM distributed d),
  earned AS (SELECT d.*, d.sp13_share_ratio * d.qtd_sp_13wk_pool AS qtd_sp13_earned, d.sp4_share_ratio * d.qtd_sp_4wk_pool AS qtd_sp4_earned, (d.qtd_ret_earned + d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_bonus_earned, (d.sp13_share_ratio * d.qtd_sp_13wk_pool + d.sp4_share_ratio * d.qtd_sp_4wk_pool) AS qtd_sales_share, d.qtd_ret_earned AS qtd_retention_share FROM ret_calc d),$r$);

  -- output row
  v_def := replace(v_def, a_out,
    $r$    ROUND(s.c_weighted_hours, 4) AS weighted_hours_at_40, ROUND(s.hours_share_ratio * 100, 4) AS retention_hours_share_pct,
    ROUND(s.c_net_points, 2) AS retention_net_points, ROUND(s.points_share_ratio * 100, 4) AS retention_points_share_pct, ROUND(s.ret_guarantee, 2) AS weekly_retention_guarantee, ROUND(s.qtd_ret_topup, 2) AS weekly_retention_topup,$r$);

  -- per-person diagnostics
  v_def := replace(v_def, a_wf,
    $r$      'retention_points', jsonb_build_object('mode', CASE WHEN v_points_mode THEN 'points' ELSE 'hours' END, 'go_live_week_end', v_rp_go_live, 'net_points', ROUND(s.c_net_points, 2), 'gross_points', ROUND(s.c_gross_points, 2), 'missed_pct', s.c_missed_pct, 'reduction_pct', s.c_reduction_pct, 'team_net_points', ROUND(s.rp_total, 2), 'points_share_pct', ROUND(s.points_share_ratio * 100, 4), 'guarantee_dollars', ROUND(s.ret_guarantee, 2), 'retention_third', ROUND(s.qtd_retention_pool, 2), 'pool_remainder_after_guarantees', ROUND(CASE WHEN v_points_mode THEN GREATEST(0, s.qtd_retention_pool - s.rp_total) ELSE 0 END, 2), 'pool_share_dollars', ROUND(CASE WHEN v_points_mode THEN s.qtd_ret_earned - s.ret_guarantee ELSE 0 END, 2), 'agency_topup_dollars', ROUND(s.qtd_ret_topup, 2), 'formula', 'points mode: retention dollars = net points (one point is one dollar, guaranteed) + points share × max(0, retention third − team net points); shortfall above the third is agency-covered and excluded from later weeks'' prior-paid subtraction. hours mode (weeks before go-live): weighted-hours share of the third.'),$r$ || chr(10) || a_wf);

  -- team-level diagnostics
  v_def := replace(v_def, a_qrp, a_qrp || chr(10) ||
    $r$        'retention_points_mode', CASE WHEN v_points_mode THEN 'points' ELSE 'hours' END, 'retention_points_team_net', ROUND(s.rp_total, 2), 'retention_guarantee_team_total', ROUND(CASE WHEN v_points_mode THEN s.rp_total ELSE 0 END, 2), 'retention_topup_team_total', ROUND((SELECT COALESCE(SUM(x.qtd_ret_topup), 0) FROM settled x), 2),$r$);

  EXECUTE 'DROP FUNCTION public.compute_weekly_comp_residual_pool(uuid, date)';
  EXECUTE v_def;
  EXECUTE 'REVOKE ALL ON FUNCTION public.compute_weekly_comp_residual_pool(uuid, date) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.compute_weekly_comp_residual_pool(uuid, date) TO authenticated, service_role';
END $mig$;

-- ---------------------------------------------------------------------------
-- 3. write_weekly_comp_v2 — store the top-up, carry the points fields into residual_pool_diag
-- ---------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def text;
  n int;
  w_share CONSTANT text := $x$        retention_pool_share = s.weekly_retention_pool_share * v_scale.scale,$x$;
  w_diag  CONSTANT text := $x$          'weighted_hours_at_40', s.weighted_hours_at_40, 'retention_hours_share_pct', s.retention_hours_share_pct,$x$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'write_weekly_comp_v2';
  IF v_def IS NULL THEN RAISE EXCEPTION 'write_weekly_comp_v2 not found'; END IF;
  IF position('retention_guarantee_topup' in v_def) > 0 THEN RAISE EXCEPTION 'already patched'; END IF;

  n := (length(v_def) - length(replace(v_def, w_share, ''))) / length(w_share);
  IF n <> 1 THEN RAISE EXCEPTION 'w_share anchor matched % times', n; END IF;
  n := (length(v_def) - length(replace(v_def, w_diag, ''))) / length(w_diag);
  IF n <> 1 THEN RAISE EXCEPTION 'w_diag anchor matched % times', n; END IF;

  v_def := replace(v_def, w_share, w_share || chr(10) ||
    $r$        retention_guarantee_topup = COALESCE(s.weekly_retention_topup, 0) * v_scale.scale,$r$);
  v_def := replace(v_def, w_diag, w_diag || chr(10) ||
    $r$          'retention_net_points', s.retention_net_points, 'retention_points_share_pct', s.retention_points_share_pct, 'weekly_retention_guarantee', s.weekly_retention_guarantee, 'weekly_retention_topup', s.weekly_retention_topup,$r$);

  EXECUTE v_def;
END $mig$;
