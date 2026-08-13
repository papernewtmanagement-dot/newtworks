-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:40:01 UTC (ledger name: fix_hiregauge_v2_careless_evenodd_round_cast) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802034001.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- round(double precision, integer) doesn't exist in Postgres; corr() returns
-- double precision. Cast to numeric before rounding.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_evenodd_consistency(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT i.hypothesized_trait AS the_trait,
           i.item_number,
           CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value
                ELSE r.response_value END AS adj
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND i.retest_of_item_number IS NULL
      AND r.response_value IS NOT NULL
  ),
  ranked AS (
    SELECT the_trait, adj,
           ROW_NUMBER() OVER (PARTITION BY the_trait ORDER BY item_number) AS pos
    FROM resp
  ),
  by_trait AS (
    SELECT the_trait,
           avg(adj) FILTER (WHERE pos % 2 = 1) AS odd_mean,
           avg(adj) FILTER (WHERE pos % 2 = 0) AS even_mean,
           count(*) AS n_items
    FROM ranked
    GROUP BY the_trait
    HAVING count(*) >= 4
  ),
  agg AS (
    SELECT count(*)::int AS n_traits,
           corr(odd_mean, even_mean)::numeric AS v_corr
    FROM by_trait
    WHERE odd_mean IS NOT NULL AND even_mean IS NOT NULL
  )
  SELECT
    CASE WHEN n_traits >= 5 THEN (v_corr IS NOT NULL AND v_corr < 0.30) ELSE false END,
    CASE
      WHEN n_traits < 5 THEN format('skipped — only %s facet(s) with >=4 items answered, need 5', n_traits)
      ELSE format('odd/even facet-mean correlation across %s facets: %s',
                   n_traits, COALESCE(round(v_corr, 2)::text, 'undefined (zero variance)'))
    END
  FROM agg;
$function$;
