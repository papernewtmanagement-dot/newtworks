
-- Batch 5 of 8.
-- job_applications: only the staff-blanket ALL policy is touched.
-- ja_anon_insert (public application-intake path) is explicitly NOT
-- touched, per standing instruction - that policy needs its own decision,
-- never a blind sweep.
-- job_postings / job_screener_questions: only the staff-blanket ALL
-- policy is touched. jp_public_active / jsq_public_active are left alone -
-- they're already scoped to active+published rows only (not a blanket
-- true), and are the live public careers-page path, same class as
-- ja_anon_insert. Not part of this sweep.

ALTER POLICY interview_questions_read ON public.interview_questions
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY ja_agency_all ON public.job_applications;
CREATE POLICY job_applications_admin_read ON public.job_applications FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_applications_auth_insert ON public.job_applications FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_applications_auth_update ON public.job_applications FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_applications_auth_delete ON public.job_applications FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY job_descriptions_auth_write ON public.job_descriptions;
CREATE POLICY job_descriptions_admin_read ON public.job_descriptions FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_descriptions_auth_insert ON public.job_descriptions FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_descriptions_auth_update ON public.job_descriptions FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_descriptions_auth_delete ON public.job_descriptions FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY job_descriptions_anon_auth_read ON public.job_descriptions
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY jp_agency_all ON public.job_postings;
CREATE POLICY job_postings_admin_read ON public.job_postings FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_postings_auth_insert ON public.job_postings FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_postings_auth_update ON public.job_postings FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_postings_auth_delete ON public.job_postings FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
-- jp_public_active intentionally untouched.

DROP POLICY jsq_agency_all ON public.job_screener_questions;
CREATE POLICY job_screener_questions_admin_read ON public.job_screener_questions FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_screener_questions_auth_insert ON public.job_screener_questions FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_screener_questions_auth_update ON public.job_screener_questions FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY job_screener_questions_auth_delete ON public.job_screener_questions FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
-- jsq_public_active intentionally untouched.

DROP POLICY lead_source_quarterly_auth_write ON public.lead_source_quarterly;
CREATE POLICY lead_source_quarterly_admin_read ON public.lead_source_quarterly FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY lead_source_quarterly_auth_insert ON public.lead_source_quarterly FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY lead_source_quarterly_auth_update ON public.lead_source_quarterly FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY lead_source_quarterly_auth_delete ON public.lead_source_quarterly FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY lsq_select_all ON public.lead_source_quarterly
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_leslie_monthly_checkin ON public.leslie_monthly_checkin
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY authenticated_write_license_notif_log ON public.license_notification_log;
CREATE POLICY license_notification_log_admin_read ON public.license_notification_log FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY license_notification_log_auth_insert ON public.license_notification_log FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY license_notification_log_auth_update ON public.license_notification_log FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY license_notification_log_auth_delete ON public.license_notification_log FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_license_notif_log ON public.license_notification_log
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_llm_parse_queue ON public.llm_parse_queue
  TO authenticated USING ( public.is_agency_admin() );

-- mvp_draw_tiers: WATCH ITEM confirmed. Write qual was auth.role()='authenticated' - any signed-in user.
DROP POLICY mvp_draw_tiers_write ON public.mvp_draw_tiers;
CREATE POLICY mvp_draw_tiers_admin_read ON public.mvp_draw_tiers FOR SELECT TO authenticated
  USING ( public.is_agency_admin() );
CREATE POLICY mvp_draw_tiers_auth_insert ON public.mvp_draw_tiers FOR INSERT TO authenticated
  WITH CHECK ( public.is_agency_admin() );
CREATE POLICY mvp_draw_tiers_auth_update ON public.mvp_draw_tiers FOR UPDATE TO authenticated
  USING ( public.is_agency_admin() ) WITH CHECK ( public.is_agency_admin() );
CREATE POLICY mvp_draw_tiers_auth_delete ON public.mvp_draw_tiers FOR DELETE TO authenticated
  USING ( public.is_agency_admin() );
ALTER POLICY mvp_draw_tiers_read ON public.mvp_draw_tiers
  TO authenticated USING ( public.is_agency_admin() );

