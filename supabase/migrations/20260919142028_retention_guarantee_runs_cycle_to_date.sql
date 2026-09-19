-- Defect found while answering Peter on what the pool already has taken out of it.
--
-- Everything else in this function is quarter-to-date: the pool, the sales shares,
-- and the netting that turns quarter-to-date earnings into a single week's pay by
-- subtracting what was already paid this cycle. The retention guarantee was the one
-- piece that was not. It was this week's net points only, while the netting still
-- subtracted every retention dollar paid earlier in the cycle. Week one of points
-- mode pays correctly; from week two on, last week's retention pay would be taken
-- back out of this week's bonus.
--
-- The guarantee, the team total it is measured against, and the share of whatever is
-- left of the third now all run cycle-to-date: prior weeks read the stored
-- retention_points_pay on the row, the current week comes in live.
DO $mig$
DECLARE
  v_def text;
  pairs text[][] := ARRAY[
    ARRAY[
      'SUM(c.c_weighted_hours) AS wh_total, SUM(c.c_net_points) AS rp_total,',
      'SUM(c.c_weighted_hours) AS wh_total, SUM(c.c_net_points) AS rp_total, SUM(c.c_qtd_rp) AS qtd_rp_total,'
    ],
    ARRAY[
      '  retention_pts AS (SELECT x.team_member_id AS tm_id,',
      '  rp_qtd AS (SELECT r.id AS tm_id, COALESCE(SUM(CASE WHEN cw.week_end_date = p_week_end_date THEN 0 ELSE COALESCE((SELECT wctd.retention_points_pay FROM public.weekly_cpr_team_detail wctd JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date LIMIT 1), 0) END), 0) AS qtd_rp_prior FROM roster r CROSS JOIN cycle_weeks cw GROUP BY r.id),
  retention_pts AS (SELECT x.team_member_id AS tm_id,'
    ],
    ARRAY[
      'wf.retention_weight_license, r.license_pc FROM roster r LEFT JOIN base_qtd b',
      'wf.retention_weight_license, r.license_pc, COALESCE(rpq.qtd_rp_prior, 0) + CASE WHEN r.shares_eligible THEN COALESCE(rpx.net_points, 0) ELSE 0 END AS c_qtd_rp FROM roster r LEFT JOIN rp_qtd rpq ON rpq.tm_id = r.id LEFT JOIN base_qtd b'
    ],
    ARRAY[
      'CASE WHEN v_points_mode THEN (CASE WHEN ps.rp_total > 0 THEN c.c_net_points / ps.rp_total ELSE 0 END) ELSE (CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END) END AS ret_share_ratio',
      'CASE WHEN v_points_mode THEN (CASE WHEN ps.qtd_rp_total > 0 THEN c.c_qtd_rp / ps.qtd_rp_total ELSE 0 END) ELSE (CASE WHEN ps.wh_total > 0 THEN c.c_weighted_hours / ps.wh_total ELSE 0 END) END AS ret_share_ratio'
    ],
    ARRAY[
      'CASE WHEN v_points_mode THEN c.c_net_points ELSE 0 END AS ret_guarantee',
      'CASE WHEN v_points_mode THEN c.c_qtd_rp ELSE 0 END AS ret_guarantee'
    ],
    ARRAY[
      'd.ret_guarantee + d.ret_share_ratio * GREATEST(0, d.qtd_retention_pool - d.rp_total)',
      'd.ret_guarantee + d.ret_share_ratio * GREATEST(0, d.qtd_retention_pool - d.qtd_rp_total)'
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
