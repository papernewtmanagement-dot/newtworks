-- Newtworks v1 assessment — Item 2 of soundness audit: careless-responding distortion signals.
-- Standard careless-responding battery for Likert-scaled sections:
--   * Straight-lining / long-string: max run of identical consecutive responses across
--     personality + impression_mgmt sections ordered by created_at (proxy for served order).
--     Flag when max_run >= 8 (~7% of a 100-item Likert battery is convention).
--   * Overall SD: standard deviation across all Likert responses. Flag when SD < 0.5
--     (near-zero variability = uniform-response careless-responding pattern).
--   * Acquiescence: arithmetic mean of RAW (not polarity-flipped) Likert responses.
--     Distance from scale midpoint (3.0 on a 1-5 scale) = agreement-bias magnitude.
--     Flag when |mean - 3.0| > 0.75 (standard convention).
-- Careless-speed flags DEFERRED to Item 4 (needs per-item timing infrastructure).

-- ─────────────────────────────────────────────────────────────────────────────
-- compute_newtworks_v1_distortion_signals
-- Single-row helper; called from compute_newtworks_v1_traits_as_row.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_distortion_signals(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL::integer,
  p_sitting integer DEFAULT NULL::integer
)
RETURNS TABLE(
  n_likert_items       integer,
  max_consecutive_run  integer,
  overall_sd           numeric,
  straight_line_flag   boolean,
  acquiescence_mean    numeric,
  acquiescence_bias    numeric,
  acquiescence_flag    boolean
)
LANGUAGE sql
STABLE
AS $function$
  WITH likert AS (
    SELECT r.response_value,
           r.created_at,
           ROW_NUMBER() OVER (ORDER BY r.created_at, r.id) AS rn
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section IN ('newtworks_v1_personality', 'newtworks_v1_impression_mgmt')
      AND r.response_value IS NOT NULL
      AND i.is_active
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  ),
  -- Gaps-and-islands: identical adjacent responses share a grp id
  grouped AS (
    SELECT response_value,
           rn,
           rn - ROW_NUMBER() OVER (PARTITION BY response_value ORDER BY rn) AS grp
    FROM likert
  ),
  runs AS (
    SELECT response_value, grp, COUNT(*)::int AS run_length
    FROM grouped
    GROUP BY response_value, grp
  ),
  agg AS (
    SELECT COUNT(*)::int                                 AS n_items,
           COALESCE(stddev_samp(response_value), 0)::numeric AS sd,
           COALESCE(avg(response_value), 0)::numeric     AS raw_mean
    FROM likert
  ),
  max_run AS (
    SELECT COALESCE(MAX(run_length), 0)::int AS max_run FROM runs
  )
  SELECT agg.n_items,
         max_run.max_run,
         round(agg.sd, 3)                                        AS overall_sd,
         (agg.n_items > 0 AND (max_run.max_run >= 8 OR agg.sd < 0.5)) AS straight_line_flag,
         round(agg.raw_mean, 3)                                  AS acquiescence_mean,
         round(abs(agg.raw_mean - 3.0), 3)                       AS acquiescence_bias,
         (agg.n_items > 0 AND abs(agg.raw_mean - 3.0) > 0.75)    AS acquiescence_flag
  FROM agg CROSS JOIN max_run;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- compute_newtworks_v1_traits_as_row — extend return with distortion signals.
-- ROW-shape change requires DROP + CREATE.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits_as_row(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits_as_row(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL::integer,
  p_sitting integer DEFAULT NULL::integer
)
RETURNS TABLE(
  candidate_id uuid,
  assertiveness integer,
  independent_spirit integer,
  compassion integer,
  belief_in_others integer,
  optimism integer,
  analytical integer,
  deadline_motivation integer,
  self_promotion integer,
  recognition_drive integer,
  overall_score integer,
  n_items_scored integer,
  cognitive_score integer,
  cognitive_n integer,
  impression_mgmt_score integer,
  impression_mgmt_n integer,
  nonsense_inflation integer,
  nonsense_n integer,
  retest_divergence numeric,
  retest_n_pairs integer,
  expansion_triggers jsonb,
  reliability_by_trait jsonb,
  -- Item 2 distortion additions:
  distortion_n_likert_items integer,
  distortion_max_consecutive_run integer,
  distortion_overall_sd numeric,
  distortion_straight_line_flag boolean,
  distortion_acquiescence_mean numeric,
  distortion_acquiescence_bias numeric,
  distortion_acquiescence_flag boolean
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  agency_id_val uuid := '126794dd-25ff-47d2-a436-724499733365';
  trait_scores jsonb;
  overall_avg int;
  n_items_total int;
  cog record;
  im record;
  nons record;
  ret record;
  dist record;
  triggers jsonb;
  reliability_json jsonb;
BEGIN
  SELECT COALESCE(jsonb_object_agg(t.trait, t.score_0_100), '{}'::jsonb),
         round(avg(t.score_0_100))::int,
         COALESCE(sum(t.n_items), 0)::int
    INTO trait_scores, overall_avg, n_items_total
    FROM public.compute_newtworks_v1_traits(p_candidate_id, p_stint, p_sitting) t;

  SELECT * INTO cog  FROM public.compute_newtworks_v1_cognitive_score      (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO im   FROM public.compute_newtworks_v1_impression_mgmt_score(p_candidate_id, p_stint, p_sitting);
  SELECT * INTO nons FROM public.compute_newtworks_v1_nonsense_inflation   (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO ret  FROM public.compute_newtworks_v1_retest_divergence    (p_candidate_id, p_sitting);
  SELECT * INTO dist FROM public.compute_newtworks_v1_distortion_signals   (p_candidate_id, p_stint, p_sitting);

  triggers := public.compute_newtworks_v1_expansion_triggers(
    agency_id_val,
    trait_scores,
    cog.score_0_100,
    im.score_0_100,
    nons.inflation_count,
    ret.avg_divergence
  );

  SELECT COALESCE(
    jsonb_object_agg(rel.trait, jsonb_build_object(
      'n_items',            rel.n_items,
      'within_trait_sd',    rel.within_trait_sd,
      'n_retest_pairs',     rel.n_retest_pairs,
      'retest_divergence',  rel.retest_divergence
    )),
    '{}'::jsonb)
    INTO reliability_json
    FROM public.compute_newtworks_v1_reliability_per_candidate(p_candidate_id, p_stint, p_sitting) rel;

  RETURN QUERY
  SELECT
    p_candidate_id,
    NULLIF(trait_scores ->> 'assertiveness',       '')::int,
    NULLIF(trait_scores ->> 'independent_spirit',  '')::int,
    NULLIF(trait_scores ->> 'compassion',          '')::int,
    NULLIF(trait_scores ->> 'belief_in_others',    '')::int,
    NULLIF(trait_scores ->> 'optimism',            '')::int,
    NULLIF(trait_scores ->> 'analytical',          '')::int,
    NULLIF(trait_scores ->> 'deadline_motivation', '')::int,
    NULLIF(trait_scores ->> 'self_promotion',      '')::int,
    NULLIF(trait_scores ->> 'recognition_drive',   '')::int,
    overall_avg,
    n_items_total,
    cog.score_0_100,
    cog.n_items,
    im.score_0_100,
    im.n_items,
    nons.inflation_count,
    nons.n_nonsense_items,
    ret.avg_divergence,
    ret.n_pairs,
    triggers,
    reliability_json,
    dist.n_likert_items,
    dist.max_consecutive_run,
    dist.overall_sd,
    dist.straight_line_flag,
    dist.acquiescence_mean,
    dist.acquiescence_bias,
    dist.acquiescence_flag;
END;
$function$;
