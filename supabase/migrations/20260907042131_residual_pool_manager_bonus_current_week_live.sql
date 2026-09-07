-- Manager bonus current-week fallback computed LIVE instead of read back from the stored row.
-- Same defect class as the 2026-07-25 commission fix: the pool read weekly_cpr_team_detail.
-- manager_bonus for the current week, which is the value write_weekly_comp_v2 is about to
-- overwrite, so the pool lagged one write cycle behind (seen 2026-09-06: John's manager bonus
-- was zeroed for his termination week, but the pool still subtracted the stale $8.71 until the
-- next run). Prior weeks unchanged: payroll actual first, stored row second.

DO $do$
DECLARE
  v_src text;
BEGIN
  v_src := pg_get_functiondef('public.compute_weekly_comp_residual_pool(uuid, date)'::regprocedure);

  v_src := public.fn_source_replace_exact(v_src,
    $q$           AND kv.key ILIKE '%Manage%'),
        (SELECT wctd.manager_bonus
         FROM public.weekly_cpr_team_detail wctd
         JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id
         WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date
         LIMIT 1),
        0
      ) AS week_mgr_paid$q$,
    $q$           AND kv.key ILIKE '%Manage%'),
        /* current week: live from this week's carve (0 if they left this week) — never the stored
           row, which this write is about to overwrite (one-cycle lag, same class as commission) */
        CASE WHEN cw.week_end_date = p_week_end_date THEN
          (CASE WHEN r.left_in_week THEN 0
                ELSE COALESCE((SELECT (mgr->>'weekly_bonus_dollars')::numeric
                               FROM jsonb_array_elements(COALESCE(v_carveouts_result->'manager_bonus'->'detail', '[]'::jsonb)) mgr
                               WHERE mgr->>'team_member_id' = r.id::text LIMIT 1), 0) END)
        END,
        (SELECT wctd.manager_bonus
         FROM public.weekly_cpr_team_detail wctd
         JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id
         WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date
         LIMIT 1),
        0
      ) AS week_mgr_paid$q$, 1);

  EXECUTE v_src;
END
$do$;
