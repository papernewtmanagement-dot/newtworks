
-- Batch 2 of 8: default-deny tier 2 sweep.
-- R1 (AND admin onto existing true/open read policy):
--   comp_category_map, comp_deduction_map, compliance_calendar,
--   compliance_log, compliance_rules, content_calendar
-- Deferred, NOT touched (pre-existing separate agency_id-only write
-- policies, per deferred write-side list): compliance_log INSERT,
-- compliance_rules INSERT, content_calendar INSERT + UPDATE.
-- R2 split (ALL policy -> 4 admin-gated policies), plus fixing the
-- separate open true-read policy that would otherwise still leak via OR:
--   daily_call_activity, email_signature_sends, email_signature_template

ALTER POLICY anon_read_comp_category_map ON public.comp_category_map
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_comp_deduction_map ON public.comp_deduction_map
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_compliance_calendar ON public.compliance_calendar
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_compliance_log ON public.compliance_log
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_compliance_rules ON public.compliance_rules
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_content_calendar ON public.content_calendar
  TO authenticated USING ( public.is_agency_admin() );

-- daily_call_activity: split the ALL policy, admin-gate all 4 commands
-- (new policies, case (a) rule), and AND admin onto the separate open
-- read policy so it can't independently leak via permissive-OR.
DROP POLICY daily_call_activity_auth_write ON public.daily_call_activity;

CREATE POLICY daily_call_activity_admin_read ON public.daily_call_activity
  FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY daily_call_activity_auth_insert ON public.daily_call_activity
  FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY daily_call_activity_auth_update ON public.daily_call_activity
  FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY daily_call_activity_auth_delete ON public.daily_call_activity
  FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY daily_call_activity_anon_auth_read ON public.daily_call_activity
  TO authenticated USING ( public.is_agency_admin() );

-- email_signature_sends: only policy was a bare "agency isolation" ALL.
DROP POLICY "agency isolation" ON public.email_signature_sends;

CREATE POLICY email_signature_sends_admin_read ON public.email_signature_sends
  FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_sends_auth_insert ON public.email_signature_sends
  FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_sends_auth_update ON public.email_signature_sends
  FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_sends_auth_delete ON public.email_signature_sends
  FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

-- email_signature_template: same shape.
DROP POLICY "agency isolation" ON public.email_signature_template;

CREATE POLICY email_signature_template_admin_read ON public.email_signature_template
  FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_template_auth_insert ON public.email_signature_template
  FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_template_auth_update ON public.email_signature_template
  FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

CREATE POLICY email_signature_template_auth_delete ON public.email_signature_template
  FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

