-- Batch 1 follow-up, found during verification:
-- Postgres RLS policies are OR'd together (permissive by default). Each of
-- these three tables had a second "ALL" policy (qual = agency_id match only,
-- no role check) left over from before. ALL implicitly covers SELECT, so it
-- was granting every authenticated user read access regardless of the new
-- SELECT-only admin policy just added. Splitting into INSERT/UPDATE/DELETE
-- only, same qual/with_check as before -- write access for staff (clocking
-- in/out, CPR checklist entry, program target maintenance) is unchanged.

DROP POLICY IF EXISTS sf_program_targets_auth_write ON public.sf_program_targets;
CREATE POLICY sf_program_targets_auth_insert ON public.sf_program_targets FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY sf_program_targets_auth_update ON public.sf_program_targets FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY sf_program_targets_auth_delete ON public.sf_program_targets FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS weekly_cpr_team_detail_auth_write ON public.weekly_cpr_team_detail;
CREATE POLICY weekly_cpr_team_detail_auth_insert ON public.weekly_cpr_team_detail FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY weekly_cpr_team_detail_auth_update ON public.weekly_cpr_team_detail FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY weekly_cpr_team_detail_auth_delete ON public.weekly_cpr_team_detail FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS time_clock_entries_auth_write ON public.time_clock_entries;
CREATE POLICY time_clock_entries_auth_insert ON public.time_clock_entries FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY time_clock_entries_auth_update ON public.time_clock_entries FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY time_clock_entries_auth_delete ON public.time_clock_entries FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- v_income_statement is now security_invoker, but its base tables
-- (journal_entries, journal_lines, chart_of_accounts) still had blanket
-- authenticated-read policies from before signed-out lockdown, so the view
-- was still wide open through them. None of the 9 team-visible modules read
-- these three tables directly -- default them to admin-only per the sweep's
-- blanket rule for untouched tables.
DROP POLICY IF EXISTS anon_read_journal_entries ON public.journal_entries;
CREATE POLICY journal_entries_admin_read ON public.journal_entries FOR SELECT TO authenticated USING (is_agency_admin());

DROP POLICY IF EXISTS anon_read_journal_lines ON public.journal_lines;
CREATE POLICY journal_lines_admin_read ON public.journal_lines FOR SELECT TO authenticated USING (is_agency_admin());

DROP POLICY IF EXISTS anon_read_chart_of_accounts ON public.chart_of_accounts;
CREATE POLICY chart_of_accounts_admin_read ON public.chart_of_accounts FOR SELECT TO authenticated USING (is_agency_admin());
