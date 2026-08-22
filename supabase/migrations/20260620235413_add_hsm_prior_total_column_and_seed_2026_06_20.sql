-- HSM prior total: cumulative Health + Service + Manager bonus paid this quarter
-- through end of last week. Manually entered weekly by Peter. Used in True Pay Bonus
-- calculation as an addition to the sales_points pool (compensation for prior weeks'
-- H/S/M payments that are present in payroll_ytd_paid but funded outside the bonus pool).
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS hsm_prior_total numeric;

COMMENT ON COLUMN public.weekly_cpr_team_detail.hsm_prior_total IS
  'Cumulative Health Bonus + Service Share + Manager Bonus paid through prior weeks this quarter (excludes this week). Manually entered weekly. Added to sales_points pool when computing True Pay Bonus.';

-- Seed Peter's values for week ending 2026-06-20
UPDATE public.weekly_cpr_team_detail wctd
SET hsm_prior_total = v.amount
FROM (VALUES
  ('John',      831.59),
  ('Thomas',    716.43),
  ('Jason',     277.05),
  ('Cassandra', 6228.39),
  ('Stephanie', 7574.53)
) AS v(first_name, amount)
JOIN public.team t ON t.first_name = v.first_name
  AND t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
WHERE wctd.team_member_id = t.id
  AND wctd.weekly_cpr_report_id = (
    SELECT id FROM public.weekly_cpr_reports
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND week_ending_date = '2026-06-20'
  );

-- Verify
SELECT t.first_name, wctd.hsm_prior_total, wctd.sales_points, wctd.payroll_ytd_paid
FROM weekly_cpr_team_detail wctd
JOIN team t ON t.id = wctd.team_member_id
WHERE wctd.weekly_cpr_report_id = (
  SELECT id FROM weekly_cpr_reports
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND week_ending_date='2026-06-20')
ORDER BY t.hire_date;
