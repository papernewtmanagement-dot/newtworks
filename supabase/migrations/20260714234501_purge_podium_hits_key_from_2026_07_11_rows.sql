-- Rename orphaned `podium_hits` JSONB key → `leaderboard_hits` on 2026-07-11 rows.
-- These rows were written before the 2026-07-14 rename migration; the key survived
-- untouched (only the formula text was fixed earlier). Move value → new key, delete old.
UPDATE public.weekly_cpr_team_detail d
SET residual_pool_diag = (
      d.residual_pool_diag
      #> '{}'
    ) || jsonb_build_object(
      'goals_detail',
      (d.residual_pool_diag->'goals_detail')
        - 'podium_hits'
        || jsonb_build_object(
             'leaderboard_hits',
             COALESCE(d.residual_pool_diag->'goals_detail'->'podium_hits', to_jsonb(0))
           )
    )
FROM public.weekly_cpr_reports r
WHERE r.id = d.weekly_cpr_report_id
  AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND r.week_ending_date = '2026-07-11'
  AND d.residual_pool_diag->'goals_detail' ? 'podium_hits';
