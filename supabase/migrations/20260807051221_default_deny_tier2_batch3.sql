-- Batch 3 of 8: default-deny tier 2 sweep.
-- R1: envelope_budget_targets, everquote_review_metrics, everquote_reviews, goals
-- R2 split (ALL -> 4 admin-gated) + fix any paired open read policy:
--   gbp_reviews, gl_classification_rules, health_quotes,
--   hiregauge_candidate_responses, hiregauge_competencies
-- hiregauge_competency_floors: two duplicate wide-open ALL policies found
-- under misleading names (anon_all_* / authenticated_all_*), both actually
-- scoped to role authenticated (verified via polroles, not by name).
-- Both dropped, replaced with one clean admin-gated set.

ALTER POLICY anon_read_envelope_budget_targets ON public.envelope_budget_targets
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY anon_read_everquote_review_metrics ON public.everquote_review_metrics
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY anon_read_everquote_reviews ON public.everquote_reviews
  TO authenticated USING ( public.is_agency_admin() );
ALTER POLICY anon_read_goals ON public.goals
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY gbp_reviews_auth_write ON public.gbp_reviews;
CREATE POLICY gbp_reviews_admin_read ON public.gbp_reviews FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gbp_reviews_auth_insert ON public.gbp_reviews FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gbp_reviews_auth_update ON public.gbp_reviews FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gbp_reviews_auth_delete ON public.gbp_reviews FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY gbp_reviews_anon_auth_read ON public.gbp_reviews
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY gl_classification_rules_auth_write ON public.gl_classification_rules;
CREATE POLICY gl_classification_rules_admin_read ON public.gl_classification_rules FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gl_classification_rules_auth_insert ON public.gl_classification_rules FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gl_classification_rules_auth_update ON public.gl_classification_rules FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY gl_classification_rules_auth_delete ON public.gl_classification_rules FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY gl_classification_rules_anon_auth_read ON public.gl_classification_rules
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY health_quotes_agency_isolation ON public.health_quotes;
CREATE POLICY health_quotes_admin_read ON public.health_quotes FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY health_quotes_auth_insert ON public.health_quotes FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY health_quotes_auth_update ON public.health_quotes FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY health_quotes_auth_delete ON public.health_quotes FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY responses_agency ON public.hiregauge_candidate_responses;
CREATE POLICY hiregauge_candidate_responses_admin_read ON public.hiregauge_candidate_responses FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_candidate_responses_auth_insert ON public.hiregauge_candidate_responses FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_candidate_responses_auth_update ON public.hiregauge_candidate_responses FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_candidate_responses_auth_delete ON public.hiregauge_candidate_responses FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

DROP POLICY hiregauge_competencies_write ON public.hiregauge_competencies;
CREATE POLICY hiregauge_competencies_admin_read ON public.hiregauge_competencies FOR SELECT TO authenticated
  USING ( public.is_agency_admin() );
CREATE POLICY hiregauge_competencies_auth_insert ON public.hiregauge_competencies FOR INSERT TO authenticated
  WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competencies_auth_update ON public.hiregauge_competencies FOR UPDATE TO authenticated
  USING ( public.is_agency_admin() ) WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competencies_auth_delete ON public.hiregauge_competencies FOR DELETE TO authenticated
  USING ( public.is_agency_admin() );
ALTER POLICY hiregauge_competencies_read ON public.hiregauge_competencies
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY anon_all_hiregauge_competency_floors ON public.hiregauge_competency_floors;
DROP POLICY authenticated_all_hiregauge_competency_floors ON public.hiregauge_competency_floors;
CREATE POLICY hiregauge_competency_floors_admin_read ON public.hiregauge_competency_floors FOR SELECT TO authenticated
  USING ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_floors_auth_insert ON public.hiregauge_competency_floors FOR INSERT TO authenticated
  WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_floors_auth_update ON public.hiregauge_competency_floors FOR UPDATE TO authenticated
  USING ( public.is_agency_admin() ) WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_floors_auth_delete ON public.hiregauge_competency_floors FOR DELETE TO authenticated
  USING ( public.is_agency_admin() );
