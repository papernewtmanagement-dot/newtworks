
-- Deferred write-side migration, run after all 8 read batches per standing
-- instruction. Gates the 8 pre-existing agency_id-only write policies on
-- is_agency_admin() too, so staff who lost read access on these tables
-- can't still silently insert/update rows in them.

ALTER POLICY authenticated_update_assessment_invitations ON public.assessment_invitations
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_update_automation_recipes ON public.automation_recipes
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_insert_compliance_log ON public.compliance_log
  TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_insert_compliance_rules ON public.compliance_rules
  TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_insert_content_calendar ON public.content_calendar
  TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_update_content_calendar ON public.content_calendar
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_insert_txn_coding_rules ON public.txn_coding_rules
  TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_update_txn_coding_rules ON public.txn_coding_rules
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

