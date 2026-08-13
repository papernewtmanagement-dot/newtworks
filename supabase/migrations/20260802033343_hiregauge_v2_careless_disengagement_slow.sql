-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:33:43 UTC (ledger name: hiregauge_v2_careless_disengagement_slow) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033343.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (b): disengagement / walked-away outliers. Meade & Craig (2012,
-- Psychological Methods) flag extreme response-time outliers as evidence a
-- respondent stepped away mid-item rather than answering carelessly-fast.
-- 180 seconds (3 minutes) on a single self-report Likert item is far beyond
-- any plausible read-and-answer time and is used here as the outlier floor.
-- Fired when any item exceeds that floor, or when 2+ items exceed 90s.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_disengagement_slow(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT r.item_id,
           EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric AS secs
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.served_at IS NOT NULL
      AND r.answered_at IS NOT NULL
  ),
  agg AS (
    SELECT count(*) FILTER (WHERE secs > 180)::int AS n_extreme,
           count(*) FILTER (WHERE secs > 90)::int AS n_moderate,
           max(secs) AS max_secs
    FROM resp
  )
  SELECT
    (n_extreme >= 1 OR n_moderate >= 2) AS fired,
    format('%s item(s) over 180s, %s item(s) over 90s, longest %.0fs',
           n_extreme, n_moderate, COALESCE(max_secs, 0)) AS detail
  FROM agg;
$function$;
