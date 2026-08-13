-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:34:03 UTC (ledger name: hiregauge_v2_careless_retest_divergence) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033403.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (d): retest divergence. Meade & Craig (2012) use within-sitting
-- retest pairs to check answer consistency — the same candidate answering
-- the same statement twice, spaced apart per the constrained-shuffle retest
-- gap. Divergence is measured on RAW response_value (both items share the
-- exact same text and scale_max, so no reverse-coding adjustment needed).
-- Fired when any pair's divergence exceeds half the item's scale range, or
-- when mean divergence across all pairs exceeds 30% of scale range.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_retest_divergence(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH pairs AS (
    SELECT orig_i.item_number AS orig_number,
           retest_i.item_number AS retest_number,
           retest_i.scale_max,
           abs(orig_r.response_value - retest_r.response_value)::numeric AS divergence
    FROM public.hiregauge_instrument_items retest_i
    JOIN public.hiregauge_instrument_items orig_i
      ON orig_i.item_number = retest_i.retest_of_item_number
     AND orig_i.section = retest_i.section
    JOIN public.hiregauge_candidate_responses retest_r
      ON retest_r.item_id = retest_i.id AND retest_r.candidate_id = p_candidate_id
    JOIN public.hiregauge_candidate_responses orig_r
      ON orig_r.item_id = orig_i.id AND orig_r.candidate_id = p_candidate_id
    WHERE retest_i.section = 'newtworks_v2_personality'
      AND retest_i.retest_of_item_number IS NOT NULL
      AND orig_r.response_value IS NOT NULL
      AND retest_r.response_value IS NOT NULL
  ),
  normed AS (
    SELECT divergence, scale_max,
           CASE WHEN scale_max > 1 THEN divergence / (scale_max - 1) ELSE 0 END AS pct_divergence
    FROM pairs
  ),
  agg AS (
    SELECT count(*)::int AS n_pairs,
           max(pct_divergence) AS max_pct,
           avg(pct_divergence) AS mean_pct
    FROM normed
  )
  SELECT
    (n_pairs > 0 AND (max_pct >= 0.50 OR mean_pct >= 0.30)) AS fired,
    format('%s retest pair(s), max divergence %.0f%% of scale, mean %.0f%% of scale',
           COALESCE(n_pairs, 0), COALESCE(max_pct, 0) * 100, COALESCE(mean_pct, 0) * 100) AS detail
  FROM agg;
$function$;
