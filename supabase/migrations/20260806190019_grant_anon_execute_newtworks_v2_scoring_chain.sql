-- Full transitive call chain under v_hiring_candidates that anon was missing
-- EXECUTE on. These are the new Newtworks v2 competency/role-fit functions
-- (built 2026-08-01 through 2026-08-06) that assessment_capability ->
-- assessment_best_fit_role -> _newtworks_role_fit_core/_gated_core ->
-- newtworks_competency_* / newtworks_role_fit_* fan out into. None of them
-- were ever granted to anon, and since the Newtworks frontend runs on the
-- plain anon key with no login, this made the entire Growth-tab candidate
-- pipeline unreadable regardless of the select-list or the earlier
-- hiring_candidates table grant fix.
GRANT EXECUTE ON FUNCTION public._assessment_dampen_trait_by_distortion(integer, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public._assessment_reliability_confidence(text) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_competency_composite(numeric[], text[], text, text) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_competency_role_context(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_integrity_decline_gate(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_reasoning_gate(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_role_fit_core(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public._newtworks_role_fit_gated_core(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.assessment_best_fit_role(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.hiregauge_v2_normalized_inputs(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_accuracy_procedural_discipline(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_autonomy_ownership(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_coachability_team_contribution(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_composure_under_pressure(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_drive_work_intensity(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_integrity(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_judgment_escalation(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_needs_discovery(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_persuasive_influence(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_rapport_building(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_resilience_under_rejection(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_competency_rule_compliance_adherence(hiring_candidates, text) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_aspirant(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_retention_escalation(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_retention_reception(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_retention_support(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_sales_in_book(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_sales_inbound(hiring_candidates) TO anon;
GRANT EXECUTE ON FUNCTION public.newtworks_role_fit_sales_outbound(hiring_candidates) TO anon;
