-- Newtworks v1 assessment — Item 5 of soundness audit: retest dedupe.
-- Retest items exist solely for retest_divergence reliability signal (which reads
-- them via retest_of_item_number join, unaffected). Feeding them back into trait
-- means double-counts them alongside the source item they retest.
-- Standard psychometric convention: retest items excluded from primary scoring.
-- Verified pre-ship on live candidates Peter + Alvi; Peter's analytical moves
-- 66 → 71 as the audit predicted; other traits shift 0-5 points as expected
-- from natural retest divergence on small item pools.
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL::integer,
  p_sitting integer DEFAULT NULL::integer
)
RETURNS TABLE(trait text, n_items integer, raw_avg numeric, score_0_100 integer)
LANGUAGE sql
STABLE
AS $function$
  WITH scored AS (
    SELECT i.hypothesized_trait AS trait,
           CASE
             WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value
             ELSE r.response_value
           END AS adj,
           i.scale_max
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND r.response_value IS NOT NULL
      AND i.is_active
      AND i.retest_of_item_number IS NULL  -- Item 5: retest items scored for reliability only
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  )
  SELECT trait,
         count(*)::int AS n_items,
         round(avg(adj)::numeric, 2) AS raw_avg,
         round(((avg(adj) - 1) / (max(scale_max) - 1) * 100)::numeric)::int AS score_0_100
  FROM scored
  GROUP BY trait
  ORDER BY trait;
$function$;
