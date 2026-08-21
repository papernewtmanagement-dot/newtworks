-- 1. Add the new column for Peter's weekly YTD payroll entry
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS payroll_ytd_paid numeric;

COMMENT ON COLUMN public.weekly_cpr_team_detail.payroll_ytd_paid IS
  'SurePayroll cumulative YTD paid for this team member through end of last pay period. Manually entered each Saturday by Peter via the Payroll Edit toggle. Used to derive QTD paid (this week minus prior quarter-end anchor) and to project On-Time annual pay.';

-- 2. Create the April 4, 2026 anchor weekly_cpr_reports row if it doesn't exist.
-- This row exists solely to hold payroll_ytd_paid values for Q1-end (= prior cycle end before
-- 2026-04-05 cycle start). It is NOT a normal CPR report — no opener, no hours, no checklist data.
INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date)
VALUES ('126794dd-25ff-47d2-a436-724499733365', '2026-04-04')
ON CONFLICT (agency_id, week_ending_date) DO NOTHING;

-- 3. Create 5 detail rows for the 5 non-Owner agency teammates who were active on 4/4/2026.
-- All hires <= 2026-04-04, no terminations before 2026-04-04.
INSERT INTO public.weekly_cpr_team_detail (agency_id, weekly_cpr_report_id, team_member_id)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  (SELECT id FROM public.weekly_cpr_reports
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND week_ending_date = '2026-04-04'),
  t.id
FROM public.team t
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND t.category = 'agency'
  AND COALESCE(t.role_level, '') <> 'Owner'
  AND t.hire_date <= '2026-04-04'
  AND (t.archived_at IS NULL OR t.archived_at > '2026-03-29'::timestamptz)
ON CONFLICT (weekly_cpr_report_id, team_member_id) DO NOTHING;

-- Verify
SELECT 'anchor_report' AS what, COUNT(*)::text AS count FROM weekly_cpr_reports
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND week_ending_date = '2026-04-04'
UNION ALL
SELECT 'anchor_detail_rows', COUNT(*)::text FROM weekly_cpr_team_detail
WHERE weekly_cpr_report_id = (SELECT id FROM weekly_cpr_reports
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND week_ending_date='2026-04-04')
UNION ALL
SELECT 'column_added', column_name FROM information_schema.columns
WHERE table_name='weekly_cpr_team_detail' AND column_name='payroll_ytd_paid';
