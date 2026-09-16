-- Permission split enforced here, not on the page.
-- authenticated only. No anon policies: these rows carry a Social Security
-- number and bank account numbers.

CREATE TRIGGER form_documents_touch BEFORE UPDATE ON public.form_documents
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER team_form_submissions_touch BEFORE UPDATE ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER team_form_secure_touch BEFORE UPDATE ON public.team_form_secure
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- form_documents: everyone signed in reads the current handbook and non-compete.
CREATE POLICY fd_read ON public.form_documents FOR SELECT TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));
CREATE POLICY fd_admin_write ON public.form_documents FOR ALL TO authenticated
  USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

-- submissions: your own, or everything if you are the owner or a manager.
CREATE POLICY tfs_read_own ON public.team_form_submissions FOR SELECT TO authenticated
  USING (team_id = public.current_team_member_id() OR public.is_agency_admin());
CREATE POLICY tfs_insert_own ON public.team_form_submissions FOR INSERT TO authenticated
  WITH CHECK (team_id = public.current_team_member_id() OR public.is_agency_admin());
-- a locked row cannot be changed by the person who filled it in.
CREATE POLICY tfs_update_own ON public.team_form_submissions FOR UPDATE TO authenticated
  USING ((team_id = public.current_team_member_id() AND locked_at IS NULL)
         OR public.is_agency_admin())
  WITH CHECK (team_id = public.current_team_member_id() OR public.is_agency_admin());
CREATE POLICY tfs_admin_delete ON public.team_form_submissions FOR DELETE TO authenticated
  USING (public.is_agency_admin());

-- secure: the new hire can WRITE their Social Security number and bank details
-- and can never read them back. Only the owner or a manager can read them,
-- and reading is what makes the purge possible.
CREATE POLICY tfsec_insert_own ON public.team_form_secure FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.team_form_submissions s
    WHERE s.id = submission_id
      AND (s.team_id = public.current_team_member_id() OR public.is_agency_admin())));
CREATE POLICY tfsec_admin_all ON public.team_form_secure FOR ALL TO authenticated
  USING (public.is_agency_admin()) WITH CHECK (public.is_agency_admin());

-- edit trail: written by whoever edits, read by the owner or a manager only.
CREATE POLICY tfe_insert ON public.team_form_edits FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.team_form_submissions s
    WHERE s.id = submission_id
      AND (s.team_id = public.current_team_member_id() OR public.is_agency_admin())));
CREATE POLICY tfe_admin_read ON public.team_form_edits FOR SELECT TO authenticated
  USING (public.is_agency_admin());
