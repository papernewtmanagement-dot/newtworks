-- Peter 2026-09-18, correcting me: retention points come out of the RETENTION
-- POOL, after the split - not off the envelope before the pool is struck. I read
-- "just like commissions" as the same place commissions come out of. He meant the
-- same mechanic, scoped to the retention third.
--
-- This puts it back exactly as it was: the third is struck (with the lapse-rate
-- floor factor applied), every net point is a guaranteed dollar out of that third,
-- whatever is left of the third is shared by points share, and a shortfall is
-- agency-covered and never clawed back. The floor can fire again, because there is
-- a third for it to scale.
DO $mig$
DECLARE
  v_def text;
  pairs text[][] := ARRAY[
    ARRAY[
      'SUM(c.c_weighted_hours) AS wh_total, SUM(c.c_net_points) AS rp_total, SUM(c.c_qtd_rp) AS qtd_rp_total,',
      'SUM(c.c_weighted_hours) AS wh_total, SUM(c.c_net_points) AS rp_total,'
    ],
    ARRAY[
      'wf.retention_weight_license, r.license_pc, COALESCE(rpq.qtd_rp_prior, 0) + CASE WHEN r.shares_eligible THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_qtd_rp FROM roster r LEFT JOIN rp_qtd rpq ON rpq.tm_id = r.id LEFT JOIN base_qtd b',
      'wf.retention_weight_license, r.license_pc FROM roster r LEFT JOIN base_qtd b'
    ],
    ARRAY[
      '  rp_qtd AS (SELECT r.id AS tm_id, COALESCE(SUM(CASE WHEN cw.week_end_date = p_week_end_date THEN 0 ELSE COALESCE((SELECT wctd.retention_points_pay FROM public.weekly_cpr_team_detail wctd JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date LIMIT 1), 0) END), 0) AS qtd_rp_prior FROM roster r CROSS JOIN cycle_weeks cw GROUP BY r.id),
  retention_pts AS (SELECT x.team_member_id AS tm_id,',
      '  retention_pts AS (SELECT x.team_member_id AS tm_id,'
    ],
    ARRAY[
      '- (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END) - (CASE WHEN v_points_mode THEN tt.qtd_rp_total ELSE 0 END) - tt.qtd_mgr_total',
      '- (CASE WHEN v_accrual_applies THEN v_comm_charge ELSE tt.qtd_comm_total END) - tt.qtd_mgr_total'
    ],
    ARRAY[
      'CASE WHEN v_points_mode THEN 0 WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0',
      'CASE WHEN v_retention_floor_factor IS NULL THEN pc.qtd_bonus_pool / 3.0'
    ],
    ARRAY[
      'CASE WHEN v_points_mode THEN d.ret_guarantee ELSE d.ret_share_ratio * d.qtd_retention_pool END AS qtd_ret_earned',
      'CASE WHEN v_points_mode THEN d.ret_guarantee + d.ret_share_ratio * GREATEST(0, d.qtd_retention_pool - d.rp_total) ELSE d.ret_share_ratio * d.qtd_retention_pool END AS qtd_ret_earned'
    ],
    ARRAY[
      '0::numeric AS qtd_ret_topup',
      'CASE WHEN v_points_mode THEN GREATEST(0, d.ret_guarantee - d.ret_share_ratio * d.qtd_retention_pool) ELSE 0 END AS qtd_ret_topup'
    ]
  ];
  i int;
  hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';
  IF v_def IS NULL THEN RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found'; END IF;

  FOR i IN 1 .. array_length(pairs, 1) LOOP
    hits := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF hits <> 1 THEN
      RAISE EXCEPTION 'anchor % matched % times, expected 1: %', i, hits, left(pairs[i][1], 70);
    END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;

  EXECUTE v_def;
END
$mig$;
