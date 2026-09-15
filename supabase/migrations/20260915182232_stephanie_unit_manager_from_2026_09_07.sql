-- Stephanie Rogers became a Unit Manager on Monday 2026-09-07 (Peter 2026-09-15).
-- public.team already carried role_level = 'Unit Manager', but the CPR week rows
-- snapshot role_level at write time and hers were written before the promotion was
-- recorded, so get_expected_teammates kept returning 'Account Manager' for those
-- weeks and compute_pool_carveouts never gave her a manager bonus.
--
-- Monday 2026-09-07 sits in the week ending 2026-09-12, so that is the first week
-- she qualifies. Weeks ending 2026-09-05 and earlier stay 'Account Manager' and are
-- deliberately untouched -- both are pool-locked and already paid.

UPDATE public.weekly_cpr_team_detail d
SET role_level = 'Unit Manager'
FROM public.weekly_cpr_reports r
WHERE r.id = d.weekly_cpr_report_id
  AND r.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND d.team_member_id = '7e161ee8-e490-46ce-903a-028390321407'
  AND r.week_ending_date >= '2026-09-12'
  AND d.role_level IS DISTINCT FROM 'Unit Manager';
