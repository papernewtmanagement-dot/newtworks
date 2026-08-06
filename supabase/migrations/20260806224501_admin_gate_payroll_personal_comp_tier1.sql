-- Peter standing rule (2026-08-06): default-deny. Anything not explicitly authorized
-- for the team is owner/manager only. Tier 1 of that sweep — highest-severity tables
-- staff could read, each verified consumed only by owner/manager modules or by nothing.
--   payroll_detail / payroll_runs : read only by Financials.jsx + Team.jsx (ADMIN_ROLES).
--   personal_register_preliminary : zero frontend refs. Peter's PERSONAL banking register.
--   team_comp_pool_schedule       : zero frontend refs. Compensation pool design.
-- Writers for all four are service-role edge functions, which bypass RLS.
-- NOT included deliberately: public.users — TimeOffRequests.jsx and TimeClock.jsx
-- (team-visible) read it, and other policies resolve identity via a users subquery.
ALTER POLICY anon_read_payroll_detail ON public.payroll_detail
  TO authenticated USING (public.is_agency_admin());
ALTER POLICY anon_read_payroll_runs ON public.payroll_runs
  TO authenticated USING (public.is_agency_admin());
ALTER POLICY authenticated_select_personal_register ON public.personal_register_preliminary
  TO authenticated USING (public.is_agency_admin());
ALTER POLICY anon_read_personal_register_preliminary ON public.personal_register_preliminary
  TO authenticated USING (public.is_agency_admin());
ALTER POLICY team_comp_pool_schedule_read ON public.team_comp_pool_schedule
  TO authenticated USING (public.is_agency_admin());

-- team_comp_pool_schedule still returned 182 rows to staff after the above, because
-- team_comp_pool_schedule_auth_write is FOR ALL and Postgres OR's permissive policies.
-- Same shape as statement_balances. Replace the ALL policy with per-command writes.
DROP POLICY team_comp_pool_schedule_auth_write ON public.team_comp_pool_schedule;
CREATE POLICY team_comp_pool_schedule_auth_insert ON public.team_comp_pool_schedule
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY team_comp_pool_schedule_auth_update ON public.team_comp_pool_schedule
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY team_comp_pool_schedule_auth_delete ON public.team_comp_pool_schedule
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- Verified: staff 0 on all four. Owner: payroll_detail 200, payroll_runs 31,
-- personal_register 6, comp_pool 182.
