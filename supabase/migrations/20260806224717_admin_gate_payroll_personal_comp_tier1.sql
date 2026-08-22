-- Peter standing rule (stated 2026-08-06): default-deny. Anything not explicitly
-- authorized for the team is owner/manager only. This is tier 1 of that sweep —
-- the highest-severity tables staff could read, all verified to be consumed only
-- by owner/manager modules (or by nothing in the frontend at all).
--
-- payroll_detail / payroll_runs : read only by Financials.jsx and Team.jsx, both
--   ADMIN_ROLES in NAV_ITEMS. Contains every team member's gross pay.
-- personal_register_preliminary : zero frontend references. Peter's PERSONAL
--   banking register — never team data under any reading.
-- team_comp_pool_schedule : zero frontend references. Compensation pool design.
--
-- Method matches the financials gate: AND the admin check onto the existing USING
-- expression, keep the policy, keep agency isolation. Where the policy is FOR ALL
-- it is replaced by per-command policies, because Postgres OR's permissive
-- policies and an ALL policy would keep admitting staff on SELECT.
-- Writers for all four are service-role edge functions, which bypass RLS.
--
-- NOT included deliberately: public.users. TimeOffRequests.jsx and TimeClock.jsx
-- (both team-visible) read it, and several other policies resolve identity via a
-- users subquery — gating it would break time off and the clock for staff.

-- payroll_detail (anon_read_payroll_detail, FOR SELECT, USING true)
ALTER POLICY anon_read_payroll_detail ON public.payroll_detail
  TO authenticated USING (public.is_agency_admin());

-- payroll_runs (anon_read_payroll_runs, FOR SELECT, USING true)
ALTER POLICY anon_read_payroll_runs ON public.payroll_runs
  TO authenticated USING (public.is_agency_admin());

-- personal_register_preliminary: two SELECT policies, both USING true
ALTER POLICY authenticated_select_personal_register ON public.personal_register_preliminary
  TO authenticated USING (public.is_agency_admin());
ALTER POLICY anon_read_personal_register_preliminary ON public.personal_register_preliminary
  TO authenticated USING (public.is_agency_admin());

-- team_comp_pool_schedule: read policy USING true; write policy stays as-is
ALTER POLICY team_comp_pool_schedule_read ON public.team_comp_pool_schedule
  TO authenticated USING (public.is_agency_admin());
