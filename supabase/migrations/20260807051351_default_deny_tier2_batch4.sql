-- Batch 4 of 8. service_role policies (hlcw_service_all,
-- hiregauge_rules_service_role_all) intentionally NOT touched.

DROP POLICY anon_all_hiregauge_competency_weights ON public.hiregauge_competency_weights;
DROP POLICY authenticated_all_hiregauge_competency_weights ON public.hiregauge_competency_weights;
CREATE POLICY hiregauge_competency_weights_admin_read ON public.hiregauge_competency_weights FOR SELECT TO authenticated
  USING ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_weights_auth_insert ON public.hiregauge_competency_weights FOR INSERT TO authenticated
  WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_weights_auth_update ON public.hiregauge_competency_weights FOR UPDATE TO authenticated
  USING ( public.is_agency_admin() ) WITH CHECK ( public.is_agency_admin() );
CREATE POLICY hiregauge_competency_weights_auth_delete ON public.hiregauge_competency_weights FOR DELETE TO authenticated
  USING ( public.is_agency_admin() );

DROP POLICY hiregauge_expansion_triggers_agency_isolation ON public.hiregauge_expansion_triggers;
CREATE POLICY hiregauge_expansion_triggers_admin_read ON public.hiregauge_expansion_triggers FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_expansion_triggers_auth_insert ON public.hiregauge_expansion_triggers FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_expansion_triggers_auth_update ON public.hiregauge_expansion_triggers FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_expansion_triggers_auth_delete ON public.hiregauge_expansion_triggers FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );

ALTER POLICY authenticated_select_hiregauge_facet_norms ON public.hiregauge_facet_norms
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY items_read_authenticated ON public.hiregauge_instrument_items
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY hlcw_read ON public.hiregauge_layer_composite_weights
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_hiregauge_role_facet_weights ON public.hiregauge_role_facet_weights
  TO authenticated USING ( public.is_agency_admin() );

ALTER POLICY anon_read_hiregauge_role_ideal_ranges ON public.hiregauge_role_ideal_ranges
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY hiregauge_rules_authenticated_agency_scope ON public.hiregauge_rules;
CREATE POLICY hiregauge_rules_admin_read ON public.hiregauge_rules FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_rules_auth_insert ON public.hiregauge_rules FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_rules_auth_update ON public.hiregauge_rules FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiregauge_rules_auth_delete ON public.hiregauge_rules FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY anon_read_hiregauge_rules ON public.hiregauge_rules
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY team_hiring_candidates_auth_write ON public.hiring_candidates;
CREATE POLICY hiring_candidates_admin_read ON public.hiring_candidates FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiring_candidates_auth_insert ON public.hiring_candidates FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiring_candidates_auth_update ON public.hiring_candidates FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY hiring_candidates_auth_delete ON public.hiring_candidates FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
ALTER POLICY staff_hiring_candidates_select ON public.hiring_candidates
  TO authenticated USING ( public.is_agency_admin() );

DROP POLICY ideas_backlog_agency_isolation ON public.ideas_backlog;
CREATE POLICY ideas_backlog_admin_read ON public.ideas_backlog FOR SELECT TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY ideas_backlog_auth_insert ON public.ideas_backlog FOR INSERT TO authenticated
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY ideas_backlog_auth_update ON public.ideas_backlog FOR UPDATE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() )
  WITH CHECK ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
CREATE POLICY ideas_backlog_auth_delete ON public.ideas_backlog FOR DELETE TO authenticated
  USING ( (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND public.is_agency_admin() );
