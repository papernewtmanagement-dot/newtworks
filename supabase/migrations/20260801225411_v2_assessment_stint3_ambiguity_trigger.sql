-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 22:54:11 UTC (ledger name: v2_assessment_stint3_ambiguity_trigger) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801225411.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- v2 Stint 3 trigger: which facets are "unclear" and need their retest item.
-- Signal used now: ambiguous score (45-55 band on the merged stint 1+2
-- score), same convention already established in v1's expansion triggers
-- (hiregauge_expansion_triggers, borderline_trait_* rows, low_bound=45,
-- high_bound=55).
--
-- This is a STARTING default, not a calibrated threshold. OQ 52220bd5 asks
-- for ambiguity ranges, within-facet variance, AND retest-divergence
-- thresholds to be tuned against live candidate data -- none of which exists
-- yet. Variance and divergence signals are NOT implemented here; only the
-- simplest, already-precedented ambiguous-score signal is. Revisit once
-- real v2 candidates have gone through the assessment.
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_stint3_triggers(
  p_candidate_id uuid
)
RETURNS TABLE (hypothesized_trait text, facet_score int)
LANGUAGE sql
STABLE
AS $fn$
  SELECT f.hypothesized_trait, f.facet_score
  FROM public.compute_newtworks_v2_facets_as_row(p_candidate_id, NULL, 1) f
  WHERE f.facet_score BETWEEN 45 AND 55
    -- Only facets that actually have a stint=3 retest item are worth
    -- flagging -- no point triggering on a facet with nothing to serve.
    AND EXISTS (
      SELECT 1 FROM public.hiregauge_instrument_items i
      WHERE i.section = 'newtworks_v2_personality'
        AND i.stint = 3
        AND i.is_active = true
        AND i.hypothesized_trait = f.hypothesized_trait
    );
$fn$;

COMMENT ON FUNCTION public.compute_newtworks_v2_stint3_triggers IS
  'v2 Stint 3 trigger: facets whose merged stint 1+2 score is ambiguous (45-55) and have a stint=3 retest item available. Starting default threshold, not calibrated -- see OQ 52220bd5. Origin 2026-08-01.';
