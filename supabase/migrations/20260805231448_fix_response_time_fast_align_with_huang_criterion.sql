-- Method (a) too-fast responding, corrected 2026-08-05 to match its own cited source.
-- Huang, Curran, Keeney, Poposki & DeShon (2012, J Business & Psychology 27:99-114)
-- validate insufficient-effort responding via OVERALL pace below ~2 seconds/item —
-- an average-rate criterion, not a proportion-of-individual-items rule. The prior
-- implementation fired when >10% of items were individually under 2s, which is a
-- stricter, uncited derivative: it tripped on a candidate at 10.1% (one item past
-- the line out of 138) whose median pace was 3.16s, fastest item 1.41s, zero
-- sub-second responses, and whose consistency indices were all clean — exactly the
-- decisive-but-valid pattern that speed-alone flags mislabel (Wood, Harms, Lowman
-- & DeSimone 2017, SPPS 8:454-464: response speed indicates carelessness only when
-- corroborated by inconsistency).
--
-- Corrected logic, two legs:
--  1. MEDIAN item time < 2s  -> the Huang et al. criterion (median over mean:
--     robust to a few long think-pauses inflating the mean).
--  2. >= 5% of items under 1s -> extreme-tail catch for mixed blitz patterns a
--     median can hide. Sub-second responses on sentence items are below reading
--     plausibility (Curran 2016, JESP 66:4-19: responses faster than the item can
--     be read are noncontent). The 5% margin (vs any single item) allows for stray
--     mobile double-taps; it is a conservative operational choice, recalibrate
--     against real-candidate data at N>=15.
-- A flat per-word reading-time floor was tested and rejected: it flagged 30% of a
-- known-valid respondent's items (chunked gist-reading of short self-statements is
-- valid and fast). Do not reintroduce word-count-scaled thresholds without
-- calibration data.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_response_time_fast(
  p_candidate_id uuid
)
RETURNS TABLE(fired boolean, detail text)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric AS secs
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.served_at IS NOT NULL
      AND r.answered_at IS NOT NULL
  ),
  agg AS (
    SELECT count(*)::int AS n_total,
           count(*) FILTER (WHERE secs < 2)::int AS n_under2,
           count(*) FILTER (WHERE secs < 1)::int AS n_under1,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY secs))::numeric AS median_secs
    FROM resp
  )
  SELECT
    (n_total > 0 AND (median_secs < 2.0
                      OR n_under1::numeric / n_total >= 0.05)) AS fired,
    format('median %ss/item across %s items; %s under 2s, %s under 1s',
           round(COALESCE(median_secs, 0), 2)::text, n_total, n_under2, n_under1) AS detail
  FROM agg;
$function$;
