-- Batch 8 of 8 (final batch). txn_coding_rules INSERT + UPDATE left
-- untouched - deferred write-side list, own migration after batch 8.

ALTER POLICY authenticated_select_txn_coding_rules ON public.txn_coding_rules
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY user_preferences_history_auth_write ON public.user_preferences_history;
CREATE POLICY user_preferences_history_admin_read ON public.user_preferences_history FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY user_preferences_history_auth_insert ON public.user_preferences_history FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY user_preferences_history_auth_update ON public.user_preferences_history FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY user_preferences_history_auth_delete ON public.user_preferences_history FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_user_preferences_history ON public.user_preferences_history
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY user_preferences_history_auth_read ON public.user_preferences_history
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY wrapup_nag_log_agency_isolation ON public.wrapup_nag_log;
CREATE POLICY wrapup_nag_log_admin_read ON public.wrapup_nag_log FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY wrapup_nag_log_auth_insert ON public.wrapup_nag_log FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY wrapup_nag_log_auth_update ON public.wrapup_nag_log FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY wrapup_nag_log_auth_delete ON public.wrapup_nag_log FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
