-- Move HSM values from this week's hsm_prior_total into last week's service_surge_share.
-- Verified safe: last week's H/S/M are all 0 for these 5 members.
UPDATE public.weekly_cpr_team_detail target
SET service_surge_share = src.hsm_prior_total
FROM (
  SELECT wctd.team_member_id, wctd.hsm_prior_total
  FROM public.weekly_cpr_team_detail wctd
  JOIN public.weekly_cpr_reports r ON r.id = wctd.weekly_cpr_report_id
  WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND r.week_ending_date = '2026-06-20'
    AND wctd.hsm_prior_total IS NOT NULL
) src
WHERE target.team_member_id = src.team_member_id
  AND target.weekly_cpr_report_id = (
    SELECT id FROM public.weekly_cpr_reports
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND week_ending_date='2026-06-13');

-- Drop the column — no longer used; HSM will be computed at runtime
ALTER TABLE public.weekly_cpr_team_detail DROP COLUMN IF EXISTS hsm_prior_total;

-- Verify
SELECT t.first_name, r.week_ending_date,
  COALESCE(wctd.service_surge_share, 0) AS service_share
FROM weekly_cpr_team_detail wctd
JOIN weekly_cpr_reports r ON r.id = wctd.weekly_cpr_report_id
JOIN team t ON t.id = wctd.team_member_id
WHERE r.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND r.week_ending_date IN ('2026-06-13', '2026-06-20')
  AND t.category='agency' AND COALESCE(t.role_level,'') <> 'Owner'
ORDER BY t.hire_date, r.week_ending_date;
