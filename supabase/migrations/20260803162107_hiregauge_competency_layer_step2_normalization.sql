-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-03 16:21:07 UTC (ledger name: hiregauge_competency_layer_step2_normalization) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260803162107.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 2 of the 12-competency rebuild (op-rule "Newtworks competency layer —
-- 12-competency library + role matrix (confirmed 2026-08-02)").
-- Normalization helper: converts each raw input to 0-100 given its own max.
-- Traits (21 personality columns) are already 0-100 via
-- compute_newtworks_v2_facets_as_row and need no normalization.
-- What DOES need normalization: gma_total_accuracy (raw count out of 16
-- active items) and the 5 SJT topic scores (raw counts out of items_taken,
-- read from sjt_topic_detail jsonb).

CREATE OR REPLACE FUNCTION public._newtworks_competency_normalize(p_raw numeric, p_max numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
BEGIN
  IF p_raw IS NULL OR p_max IS NULL OR p_max <= 0 THEN
    RETURN NULL;
  END IF;
  RETURN LEAST(100, GREATEST(0, ROUND(100.0 * p_raw / p_max, 1)));
END;
$fn$;

COMMENT ON FUNCTION public._newtworks_competency_normalize(numeric, numeric) IS
'Generic 0-100 normalizer for raw-count inputs feeding the 12-competency
library (op-rule "Newtworks competency layer — 12-competency library + role
matrix"). NULL-safe: any NULL or non-positive max returns NULL, never a
partial/garbage value. Per the 0-100 universal grading-scale rule.';

CREATE OR REPLACE FUNCTION public._newtworks_reasoning_score(p_candidate public.hiring_candidates)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT public._newtworks_competency_normalize(p_candidate.gma_total_accuracy, 16);
$fn$;

COMMENT ON FUNCTION public._newtworks_reasoning_score(public.hiring_candidates) IS
'Normalizes gma_total_accuracy (raw count, 16 active GMA items: 4 pattern +
4 deductive + 4 numerical + 4 verbal) to 0-100. This is the single
"reasoning total" input consumed additively by competencies 4
(needs_discovery), 7 (accuracy_procedural_discipline), and 10
(judgment_escalation) per op-rule "Newtworks competency layer". Reasoning
enters as a component, never a multiplier — Van Iddekinge, Aguinis, Mackey &
DeOrtentiis 2018, J. Management 44, 249-279.';

CREATE OR REPLACE FUNCTION public._newtworks_sjt_topic_score(p_candidate public.hiring_candidates, p_topic text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT public._newtworks_competency_normalize(
    (p_candidate.sjt_topic_detail -> p_topic ->> 'correct')::numeric,
    (p_candidate.sjt_topic_detail -> p_topic ->> 'n')::numeric
  );
$fn$;

COMMENT ON FUNCTION public._newtworks_sjt_topic_score(public.hiring_candidates, text) IS
'Normalizes one SJT topic to 0-100 by reading correct/n from
sjt_topic_detail jsonb (populated by apply_newtworks_v2_sjt_to_candidate).
Divides by actual n answered rather than a hardcoded 4 — same expected
result for any candidate who completed the section (each active topic has
exactly 4 items), but correct if item counts ever change. Valid p_topic
values (5 active): sjt_composure_under_load, sjt_compliance_licensing_boundary,
sjt_compliance_outbound_consent, sjt_honesty_integrity, sjt_escalation_judgment.
Unknown/inactive topic key or missing data returns NULL, not zero.';
