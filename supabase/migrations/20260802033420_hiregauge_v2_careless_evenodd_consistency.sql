-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:34:20 UTC (ledger name: hiregauge_v2_careless_evenodd_consistency) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033420.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Method (e): even-odd consistency. Meade & Craig (2012) individual-reliability
-- index: within one respondent, split each facet's items into odd/even
-- positions, take the mean of each half, then correlate the odd-half means
-- against the even-half means ACROSS facets for that one person. A careless
-- respondent shows no consistent relationship between their own odd- and
-- even-item averages across traits; an attentive one does. Computable at
-- N=1 candidate (correlates across traits, not across candidates) — same
-- within-person design as compute_newtworks_v1_reliability_per_candidate.
-- Requires at least 5 facets with >=4 answered baseline items to be
-- statistically meaningful; returns fired=false with a skip note below that.
-- Excludes retest items (already covered by method d) and non-facet items
-- (IM/vocab, hypothesized_trait IS NULL).
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_evenodd_consistency(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_n_traits int;
  v_corr numeric;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _eo_resp ON COMMIT DROP AS
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
  )
  SELECT the_trait,
         avg(adj) FILTER (WHERE pos % 2 = 1) AS odd_mean,
         avg(adj) FILTER (WHERE pos % 2 = 0) AS even_mean,
         count(*) AS n_items
  FROM ranked
  GROUP BY the_trait
  HAVING count(*) >= 4;

  SELECT count(*) INTO v_n_traits FROM _eo_resp WHERE odd_mean IS NOT NULL AND even_mean IS NOT NULL;

  IF v_n_traits < 5 THEN
    RETURN QUERY SELECT false, format('skipped — only %s facet(s) with >=4 items answered, need 5', v_n_traits);
    RETURN;
  END IF;

  SELECT corr(odd_mean, even_mean) INTO v_corr FROM _eo_resp;

  RETURN QUERY SELECT
    (v_corr IS NOT NULL AND v_corr < 0.30) AS fired,
    format('odd/even facet-mean correlation across %s facets: %s',
           v_n_traits, COALESCE(round(v_corr, 2)::text, 'undefined (zero variance)'));
END;
$function$;
