-- Backfill team_weekly_snapshot for existing weekly_cpr_reports rows.
-- Uses current team state as best-available fallback for historical weeks.
-- Any pre-existing role/state drift can be manually corrected after backfill.

INSERT INTO public.team_weekly_snapshot (
  agency_id, team_member_id, week_ending_date,
  first_name, last_name, nickname,
  role, role_level, role_category, category,
  is_active, archived_at, is_admin_backoffice, is_test_user,
  start_date, end_date,
  pay_type, pay_rate, pay_frequency,
  annual_benefits_value,
  weekly_life_benefit_agency_paid, weekly_health_benefit_agency_paid,
  work_location,
  source
)
SELECT
  t.agency_id, t.id, r.week_ending_date,
  t.first_name, t.last_name, t.nickname,
  t.role, t.role_level, t.role_category, t.category,
  t.is_active, t.archived_at, t.is_admin_backoffice, t.is_test_user,
  t.start_date, t.end_date,
  t.pay_type, t.pay_rate, t.pay_frequency,
  t.annual_benefits_value,
  t.weekly_life_benefit_agency_paid, t.weekly_health_benefit_agency_paid,
  t.work_location,
  'backfill'
FROM public.weekly_cpr_reports r
JOIN public.team t
  ON t.agency_id = r.agency_id
 AND (t.archived_at IS NULL OR t.archived_at > (r.week_ending_date - INTERVAL '6 days'))
ON CONFLICT (agency_id, team_member_id, week_ending_date) DO NOTHING;

-- Stephanie Rogers 2026-07-11 role_level correction: promoted today,
-- was Account Associate last week.
UPDATE public.team_weekly_snapshot
SET role_level = 'Account Associate',
    source     = 'manual',
    taken_at   = now()
WHERE agency_id     = '126794dd-25ff-47d2-a436-724499733365'
  AND team_member_id = '7e161ee8-e490-46ce-903a-028390321407'
  AND week_ending_date < '2026-07-13';
