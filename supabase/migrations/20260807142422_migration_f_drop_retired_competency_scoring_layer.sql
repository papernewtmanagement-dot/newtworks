-- Migration F: drop retired competency scoring layer.
-- Authorized by Peter 2026-08-07 (own + Marie's placements confirmed correct
-- under facet-direct). F.1 (probes re-key) already deployed and verified
-- (v20 ACTIVE, sales_outbound SELECT returns 9 rows at weight>=2).
-- F.2 safety grep (run this session) found zero unexpected hits: all callers
-- of the 16 dropped functions are each other or the drop-list itself; the
-- one hit on _newtworks_integrity_decline_gate is docstring text only,
-- verified directly against its function body, not edited. Old scores
-- preserved permanently in hiregauge_role_fit_pre_facet_snapshot -- never
-- touched by this migration.

-- 13 newtworks_competency_* functions (single overload each)
DROP FUNCTION IF EXISTS public.newtworks_competency_accuracy_procedural_discipline(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_autonomy_ownership(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_coachability_team_contribution(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_composure_under_pressure(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_drive_work_intensity(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_gma(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_integrity(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_judgment_escalation(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_needs_discovery(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_persuasive_influence(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_rapport_building(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_resilience_under_rejection(hiring_candidates, text);
DROP FUNCTION IF EXISTS public.newtworks_competency_rule_compliance_adherence(hiring_candidates, text);

-- 2 composite/context helpers
DROP FUNCTION IF EXISTS public._newtworks_competency_composite(numeric[], text[], text, text);
DROP FUNCTION IF EXISTS public._newtworks_competency_role_context(uuid, text, text);

-- Orphaned gate function -- BOTH overloads (verified live: two distinct
-- signatures exist, neither called by anything)
DROP FUNCTION IF EXISTS public.apply_newtworks_v2_competency_gates_to_candidate(uuid);
DROP FUNCTION IF EXISTS public.apply_newtworks_v2_competency_gates_to_candidate(uuid, text);

-- Drift-check machinery (validated the COMPETENCY_FACET_INPUTS map in the
-- edge function, which no longer exists as of F.1)
SELECT cron.unschedule(19); -- hiregauge_facet_drift_monthly
DROP FUNCTION IF EXISTS public.hiregauge_detect_facet_input_drift();
DROP TABLE IF EXISTS public.hiregauge_competency_facet_canonical;

-- 2 weight/floor tables
DROP TABLE IF EXISTS public.hiregauge_competency_weights;
DROP TABLE IF EXISTS public.hiregauge_competency_floors;
