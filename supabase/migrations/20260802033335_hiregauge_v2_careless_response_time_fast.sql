-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:33:35 UTC (ledger name: hiregauge_v2_careless_response_time_fast) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033335.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (a): too-fast responding. Huang, Curran, Keeney, Poposki & DeShon
-- (2012, J. Business & Psychology) index insufficient-effort responding via
-- per-item response time below a floor consistent with actually reading the
-- item (2 seconds/item is their commonly-cited screening threshold). Fired
-- when more than 10% of a candidate's v2 personality items were answered in
-- under 2 seconds.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_response_time_fast(
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
    SELECT count(*)::int AS n_total,
           count(*) FILTER (WHERE secs < 2)::int AS n_fast
    FROM resp
  )
  SELECT
    (n_total > 0 AND n_fast::numeric / n_total > 0.10) AS fired,
    format('%s of %s items answered in under 2s (%.1f%%)',
           n_fast, n_total,
           CASE WHEN n_total > 0 THEN 100.0 * n_fast / n_total ELSE 0 END) AS detail
  FROM agg;
$function$;
