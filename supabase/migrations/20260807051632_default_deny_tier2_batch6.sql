
-- Batch 6 of 8. open_questions_service_role_all untouched (service_role).
-- sales_points_band_write_owner untouched - already scoped to owner role
-- only via subquery, stricter than is_agency_admin(), not the leak source.

ALTER POLICY mvp_prize_draws_select ON public.mvp_prize_draws
  TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY open_questions_agency_all ON public.open_questions;
CREATE POLICY open_questions_admin_read ON public.open_questions FOR SELECT TO authenticated
  USING ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() );
CREATE POLICY open_questions_auth_insert ON public.open_questions FOR INSERT TO authenticated
  WITH CHECK ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() );
CREATE POLICY open_questions_auth_update ON public.open_questions FOR UPDATE TO authenticated
  USING ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() );
CREATE POLICY open_questions_auth_delete ON public.open_questions FOR DELETE TO authenticated
  USING ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() );
ALTER POLICY anon_read_open_questions ON public.open_questions
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_paper_newt_ventures ON public.paper_newt_ventures
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_payroll_label_map ON public.payroll_label_map
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_producer_production ON public.producer_production
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY referrals_auth_write ON public.referrals;
CREATE POLICY referrals_admin_read ON public.referrals FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY referrals_auth_insert ON public.referrals FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY referrals_auth_update ON public.referrals FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY referrals_auth_delete ON public.referrals FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY referrals_anon_auth_read ON public.referrals
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY retention_budget_schedule_auth_write ON public.retention_budget_schedule;
CREATE POLICY retention_budget_schedule_admin_read ON public.retention_budget_schedule FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY retention_budget_schedule_auth_insert ON public.retention_budget_schedule FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY retention_budget_schedule_auth_update ON public.retention_budget_schedule FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY retention_budget_schedule_auth_delete ON public.retention_budget_schedule FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY retention_budget_schedule_anon_auth_read ON public.retention_budget_schedule
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_role_pace_targets ON public.role_pace_targets
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_sales_points_band_config ON public.sales_points_band_config
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY sales_points_band_read_agency ON public.sales_points_band_config
  TO authenticated
  USING ( (agency_id IN ( SELECT u.agency_id FROM users u WHERE (u.auth_user_id = auth.uid()) )) AND public.is_agency_admin() );

ALTER POLICY anon_read_social_accounts ON public.social_accounts
  TO authenticated USING ( public.is_agency_admin() );

