-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 22:41:43 UTC (ledger name: v2_assessment_facet_scoring_function) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801224143.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- v2 assessment: facet-level scoring function
-- Scores newtworks_v2_personality items directly into their published facet
-- (hypothesized_trait), NOT into the competency/role-fit layer -- that layer
-- is explicitly deferred (OQ f979e377) pending Peter's decision on 8 orphaned
-- competency functions. This function only produces the raw psychometric
-- profile the assessment itself depends on.
--
-- Method: unit-weighted mean per facet, normalized 0-100, reverse-coding
-- applied pre-normalization. Unit-weighting is the accurate choice here, not
-- just the simple one (Wainer 1976; Ree, Carretta & Earles 1998) -- per
-- operational_rule "Hardcoded functions: never prefer simpler over more
-- accurate."
--
-- Two-stint architecture note: Stint 1 (33 items) is the HEXACO
-- Honesty-Humility integrity gate (sincerity, fairness, greed_avoidance).
-- Stint 2 (211 items) is every other facet, served unconditionally once
-- Stint 1 is complete -- NOT per-trait adaptive expansion like v1. This
-- function scores whatever has been answered so far, so it works correctly
-- whether called mid-stint-1 (gate-only) or after both stints (full profile).

CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_facets_as_row(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT 1
)
RETURNS TABLE (
  hypothesized_trait text,
  facet_score int,
  n_items_scored int
)
LANGUAGE sql
STABLE
AS $fn$
  WITH scored_items AS (
    SELECT
      i.hypothesized_trait,
      i.scale_max,
      i.reverse_coded,
      r.response_value
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality'
      AND i.is_active = true
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND r.response_value IS NOT NULL
      AND i.scale_max IS NOT NULL
      AND i.scale_max > 1
  ),
  normalized AS (
    SELECT
      hypothesized_trait,
      CASE
        WHEN reverse_coded THEN
          ((scale_max - response_value) / (scale_max - 1.0)) * 100.0
        ELSE
          ((response_value - 1) / (scale_max - 1.0)) * 100.0
      END AS pct
    FROM scored_items
  )
  SELECT
    hypothesized_trait,
    ROUND(AVG(pct))::int AS facet_score,
    COUNT(*)::int AS n_items_scored
  FROM normalized
  WHERE hypothesized_trait IS NOT NULL
  GROUP BY hypothesized_trait;
$fn$;

COMMENT ON FUNCTION public.compute_newtworks_v2_facets_as_row IS
  'v2 assessment facet-level scoring. Unit-weighted mean per hypothesized_trait, normalized 0-100, reverse-coding applied. Scope: raw facet scores only -- does NOT compute competency or role-fit layer (deferred, OQ f979e377). Origin: 2026-08-01, built to unblock v2 assessment delivery.';
