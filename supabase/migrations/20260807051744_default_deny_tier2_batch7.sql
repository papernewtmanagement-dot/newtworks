
-- Batch 7 of 8. tovr_owner_read and notification_log_read_owner untouched -
-- already scoped to owner role specifically, stricter than is_agency_admin(),
-- not the leak source on those two tables.

ALTER POLICY anon_read_social_analytics ON public.social_analytics
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_sops ON public.sops
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY team_checkin_runs_agency_isolation ON public.team_checkin_runs;
CREATE POLICY team_checkin_runs_admin_read ON public.team_checkin_runs FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkin_runs_auth_insert ON public.team_checkin_runs FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkin_runs_auth_update ON public.team_checkin_runs FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkin_runs_auth_delete ON public.team_checkin_runs FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_team_checkin_runs ON public.team_checkin_runs
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY team_checkins_agency_isolation ON public.team_checkins;
CREATE POLICY team_checkins_admin_read ON public.team_checkins FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkins_auth_insert ON public.team_checkins FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkins_auth_update ON public.team_checkins FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_checkins_auth_delete ON public.team_checkins FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_team_checkins ON public.team_checkins
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY team_health_checkins_agency_isolation ON public.team_health_checkins;
CREATE POLICY team_health_checkins_admin_read ON public.team_health_checkins FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_health_checkins_auth_insert ON public.team_health_checkins FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_health_checkins_auth_update ON public.team_health_checkins FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_health_checkins_auth_delete ON public.team_health_checkins FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY team_profile_agency_isolation ON public.team_profile;
CREATE POLICY team_profile_admin_read ON public.team_profile FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_profile_auth_insert ON public.team_profile FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_profile_auth_update ON public.team_profile FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY team_profile_auth_delete ON public.team_profile FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_team_profile ON public.team_profile
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_telegram_group_messages ON public.telegram_group_messages
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY telegram_group_messages_authenticated_read ON public.telegram_group_messages
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_time_off_coverage_rules ON public.time_off_coverage_rules
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_time_off_email_vote_replies ON public.time_off_email_vote_replies
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_time_off_notification_log ON public.time_off_notification_log
  TO authenticated USING ( public.is_agency_admin() );

