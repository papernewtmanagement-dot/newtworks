-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:33:52 UTC (ledger name: hiregauge_v2_careless_straightlining) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033352.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (c): straightlining / long-string index. Johnson (2005) and Huang,
-- Curran, Keeney, Poposki & DeShon (2012) use the longest unbroken run of
-- identical response values ("long string") as a careless-responding signal;
-- Huang et al. use a threshold around 10 consecutive identical responses.
-- Computed on RAW response_value (not reverse-coded) since straightlining is
-- about literal answer repetition, not adjusted trait direction. Ordered by
-- served_at (actual served order for this candidate), not item_number.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_straightlining(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH ordered AS (
    SELECT r.response_value,
           r.served_at,
           ROW_NUMBER() OVER (ORDER BY r.served_at) AS pos
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.response_value IS NOT NULL
      AND r.served_at IS NOT NULL
  ),
  grp AS (
    SELECT response_value, pos,
           pos - ROW_NUMBER() OVER (PARTITION BY response_value ORDER BY pos) AS grp_key
    FROM ordered
  ),
  runs AS (
    SELECT response_value, count(*)::int AS run_length
    FROM grp
    GROUP BY response_value, grp_key
  ),
  agg AS (
    SELECT COALESCE(max(run_length), 0) AS longest_run
    FROM runs
  )
  SELECT
    (longest_run >= 10) AS fired,
    format('longest identical-response run: %s items', longest_run) AS detail
  FROM agg;
$function$;
