-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 22:59:50 UTC (ledger name: v2_assessment_stint3_trigger_stint12_only) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801225950.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Bug found in same-session testing: compute_newtworks_v2_stint3_triggers
-- called compute_newtworks_v2_facets_as_row with p_stint=NULL (merge all
-- stints), which means once a candidate started answering stint=3 items,
-- their own answers fed back into the score deciding whether stint 3 should
-- have been triggered in the first place -- a facet already served for
-- retest could silently drop out of the trigger set mid-session as more
-- stint-3 answers landed. The trigger must read stint 1+2 ONLY -- it decides
-- what to serve BEFORE stint 3 exists, so it can never look at stint 3 data.
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_stint3_triggers(
  p_candidate_id uuid
)
RETURNS TABLE (hypothesized_trait text, facet_score int)
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
      AND r.sitting = 1
      AND i.section = 'newtworks_v2_personality'
      AND i.is_active = true
      AND i.stint IN (1, 2)  -- stint 1+2 ONLY -- never stint 3
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
  ),
  facets AS (
    SELECT hypothesized_trait, ROUND(AVG(pct))::int AS facet_score
    FROM normalized
    WHERE hypothesized_trait IS NOT NULL
    GROUP BY hypothesized_trait
  )
  SELECT f.hypothesized_trait, f.facet_score
  FROM facets f
  WHERE f.facet_score BETWEEN 45 AND 55
    AND EXISTS (
      SELECT 1 FROM public.hiregauge_instrument_items i
      WHERE i.section = 'newtworks_v2_personality'
        AND i.stint = 3
        AND i.is_active = true
        AND i.hypothesized_trait = f.hypothesized_trait
    );
$fn$;

COMMENT ON FUNCTION public.compute_newtworks_v2_stint3_triggers IS
  'v2 Stint 3 trigger: facets whose stint 1+2 ONLY score is ambiguous (45-55) and have a stint=3 retest item available. Reads stint 1+2 exclusively -- never stint 3 -- so the trigger set is stable once computed and does not retract items already served. Starting default threshold, not calibrated -- see OQ 52220bd5. Fixed 2026-08-01 after same-session testing caught a stint-3-answers-affecting-the-trigger bug.';
