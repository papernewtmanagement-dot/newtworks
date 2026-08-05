-- Batch 1: lock every table flagged in the per-person staff-read sweep to
-- owner/manager only. Replaces blanket authenticated-read policies (qual=true)
-- with is_agency_admin(). Column-level split (team, weekly_cpr_team_detail,
-- v_time_clock_status, growth budget views) deferred to a follow-up per
-- Peter's call -- full table lock now.
-- NOTE: aipp_tracking dropped from this batch -- table does not exist in the
-- schema; Dashboard.jsx's query against it is dead code (fails silently).

-- agency
DROP POLICY IF EXISTS anon_read_agency ON public.agency;
CREATE POLICY agency_admin_read ON public.agency FOR SELECT TO authenticated USING (is_agency_admin());

-- alerts
DROP POLICY IF EXISTS anon_read_alerts ON public.alerts;
CREATE POLICY alerts_admin_read ON public.alerts FOR SELECT TO authenticated USING (is_agency_admin());

-- comp_recap
DROP POLICY IF EXISTS anon_read_comp_recap ON public.comp_recap;
CREATE POLICY comp_recap_admin_read ON public.comp_recap FOR SELECT TO authenticated USING (is_agency_admin());

-- documents
DROP POLICY IF EXISTS anon_read_documents ON public.documents;
CREATE POLICY documents_admin_read ON public.documents FOR SELECT TO authenticated USING (is_agency_admin());

-- monthly_close_checklist
DROP POLICY IF EXISTS anon_read_monthly_close_checklist ON public.monthly_close_checklist;
CREATE POLICY monthly_close_checklist_admin_read ON public.monthly_close_checklist FOR SELECT TO authenticated USING (is_agency_admin());

-- persistent_memory
DROP POLICY IF EXISTS anon_read_persistent_memory ON public.persistent_memory;
CREATE POLICY persistent_memory_admin_read ON public.persistent_memory FOR SELECT TO authenticated USING (is_agency_admin());

-- sf_program_targets
DROP POLICY IF EXISTS sf_program_targets_anon_read ON public.sf_program_targets;
CREATE POLICY sf_program_targets_admin_read ON public.sf_program_targets FOR SELECT TO authenticated USING (is_agency_admin());

-- tasks
DROP POLICY IF EXISTS anon_read_tasks ON public.tasks;
CREATE POLICY tasks_admin_read ON public.tasks FOR SELECT TO authenticated USING (is_agency_admin());

-- team
DROP POLICY IF EXISTS anon_read_team ON public.team;
CREATE POLICY team_admin_read ON public.team FOR SELECT TO authenticated USING (is_agency_admin());

-- weekly_cpr_team_detail
DROP POLICY IF EXISTS weekly_cpr_team_detail_anon_auth_read ON public.weekly_cpr_team_detail;
CREATE POLICY weekly_cpr_team_detail_admin_read ON public.weekly_cpr_team_detail FOR SELECT TO authenticated USING (is_agency_admin());

-- time_clock_entries: two duplicate blanket-read policies existed; drop both,
-- replace with admin-or-own-row (clock entries themselves aren't pay data --
-- pay_rate lives on team, already locked above; keep clock in/out team-usable).
DROP POLICY IF EXISTS time_clock_entries_anon_read ON public.time_clock_entries;
DROP POLICY IF EXISTS time_clock_entries_authenticated_read ON public.time_clock_entries;
CREATE POLICY time_clock_entries_admin_or_own_read ON public.time_clock_entries FOR SELECT TO authenticated
  USING (is_agency_admin() OR team_member_id = current_team_member_id());

-- Views feeding team-visible screens run with definer/owner privileges by
-- default (reloptions confirmed null = security_invoker off), which means
-- they bypass RLS on their base tables entirely. Flip them to invoker so
-- the locks above actually take effect through the view.
ALTER VIEW public.v_income_statement SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_current SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_ytd SET (security_invoker = true);
ALTER VIEW public.v_time_clock_status SET (security_invoker = true);
