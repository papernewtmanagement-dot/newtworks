-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:34:29 UTC (ledger name: hiregauge_v2_careless_bogus_items) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033429.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (f): bogus/over-claiming items. Paulhus (2003) over-claiming
-- technique: invented-word "vocabulary" items with a known-correct answer
-- ("None of these") — a candidate claiming knowledge of a nonexistent word
-- is either careless or overclaiming. Fired when a candidate misses 50%+ of
-- the served bogus items. is_correct is already computed at save time
-- (edge fn compares response_label to answer_key), so this reads that.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_bogus_items(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT r.is_correct
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND i.is_nonsense = true
  ),
  agg AS (
    SELECT count(*)::int AS n_total,
           count(*) FILTER (WHERE is_correct = false)::int AS n_wrong
    FROM resp
  )
  SELECT
    (n_total > 0 AND n_wrong::numeric / n_total >= 0.50) AS fired,
    format('%s of %s bogus/over-claiming items missed', n_wrong, n_total) AS detail
  FROM agg;
$function$;
