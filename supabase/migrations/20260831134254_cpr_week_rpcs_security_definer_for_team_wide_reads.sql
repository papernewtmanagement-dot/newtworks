-- Peter reported 2026-08-31: on the CPR page a teammate sees their OWN Scorecard
-- box checked and every other teammate's as an X, even in a week where everyone
-- filed. Peter (admin) sees all checks. Not a display bug - a permissions bug.
--
-- ROOT CAUSE: compute_scorecard_done_for_cpr_week is SECURITY INVOKER. Its driver
-- CTE reads public.weekly_cpr_team_detail, which carries the row-level policy
-- weekly_cpr_team_detail_admin_or_own_read (is_agency_admin() OR own row). So for
-- a non-admin caller the function returns exactly ONE row - their own. CPRDetail.jsx
-- then treats "absent from the result" as done = false, blanking every other
-- teammate's checkmark AND writing that false back to the base table (the UPDATE
-- policy is agency-wide, so the write succeeded). Peter's next page load recomputed
-- them all back to true, which is why the corruption never stuck long enough to see.
-- The companion JS guard (never write off an absent key) ships with this.
--
-- SAME CLASS, same page, fixed in the same pass:
--   get_weekly_cpr_hours        - hours grid, reads team + weekly_cpr_team_detail
--                                 + time_off_requests; non-admin saw only their own row
--   get_weekly_cpr_requirements - drives the team win-the-week totals; a non-admin
--                                 viewer's totals silently summed one person
--   fit_scorecard_tenure_tier   - reads public.team (also admin-or-own); returned the
--                                 weeks_14_plus fallback for anyone but yourself, which
--                                 also mis-stamps entry_type when a lead files a card
--                                 for a teammate
--
-- WHY DEFINER IS THE RIGHT FIX HERE (not loosening the table policies): the comp
-- columns on weekly_cpr_team_detail - pay, bonuses, pools, warning/coverage/
-- profitability - MUST stay admin-or-own. That part of the policy is correct and is
-- untouched. These four functions return activity only (completion booleans, tenure
-- tier, hours, quote requirements), all of which already go to the whole team in the
-- weekly CPR email. Same reasoning as the weekly_cpr_team_detail_activity view
-- (20260810134335) and team_directory: split by COLUMN, not by row.
--
-- Execute is granted to authenticated + service_role only - never anon - so this
-- exposes nothing to an unauthenticated caller.

ALTER FUNCTION public.compute_scorecard_done_for_cpr_week(uuid, date) SECURITY DEFINER;
ALTER FUNCTION public.compute_scorecard_done_for_cpr_week(uuid, date) SET search_path = public, pg_temp;

ALTER FUNCTION public.fit_scorecard_tenure_tier(uuid, date) SECURITY DEFINER;
ALTER FUNCTION public.fit_scorecard_tenure_tier(uuid, date) SET search_path = public, pg_temp;

ALTER FUNCTION public.get_weekly_cpr_hours(uuid, date) SECURITY DEFINER;
ALTER FUNCTION public.get_weekly_cpr_hours(uuid, date) SET search_path = public, pg_temp;

ALTER FUNCTION public.get_weekly_cpr_requirements(uuid, date) SECURITY DEFINER;
ALTER FUNCTION public.get_weekly_cpr_requirements(uuid, date) SET search_path = public, pg_temp;
