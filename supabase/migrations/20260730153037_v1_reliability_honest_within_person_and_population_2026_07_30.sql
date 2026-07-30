-- Newtworks v1 assessment — reliability measures (Item 1 of the v1 soundness audit).
-- Consolidated mirror of three DB-applied migrations from 2026-07-30:
--   * 20260730152818 v1_reliability_measures_2026_07_30                (superseded)
--   * 20260730152851 v1_reliability_fix_var_shadowing_2026_07_30       (superseded)
--   * 20260730153037 v1_reliability_honest_within_person_and_population_2026_07_30 (final)
-- Squashed to the final live state per handoff. A fresh `supabase db reset` from this
-- file must produce byte-equivalent function definitions for the two reliability
-- functions and the reliability_by_trait extension on compute_newtworks_v1_traits_as_row.
--
-- Architecture (standard psychometric convention):
--   * Per-candidate function returns within-person signals only (per-trait SD of
--     polarity-flipped adjusted responses + per-trait retest divergence). Safe to
--     call for N=1; feeds compute_newtworks_v1_traits_as_row.reliability_by_trait.
--   * Population function returns classical Cronbach's alpha + Spearman-Brown
--     split-half across all v1 candidates in the agency. Requires N>=p_min_n
--     (default 10); returns NULLs below threshold. Excludes retest items so they
--     don't double-weight.
-- First attempt attempted Cronbach + classical split-half from N=1 and produced
-- invalid math (item-total r trivially = -1.00 correlating x vs total-x;
-- Spearman-Brown blew up on negative half-r). This is the corrected form.

-- ─────────────────────────────────────────────────────────────────────────────
-- compute_newtworks_v1_reliability_per_candidate
-- Within-person signals only. Called per candidate; safe at N=1.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_reliability_per_candidate(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL::integer,
  p_sitting integer DEFAULT NULL::integer
)
RETURNS TABLE(
  trait text,
  n_items integer,
  within_trait_sd numeric,
  n_retest_pairs integer,
  retest_divergence numeric
)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT i.hypothesized_trait AS the_trait,
           i.item_number,
           i.retest_of_item_number,
           i.scale_max,
           CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END AS adj,
           r.response_value AS raw
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND r.response_value IS NOT NULL
      AND i.is_active
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  ),
  by_trait AS (
    SELECT the_trait,
           count(*)::int AS n,
           stddev_samp(adj)::numeric AS sd
    FROM resp
    GROUP BY the_trait
  ),
  retest_pairs AS (
    SELECT src.the_trait,
           abs(rt.raw - src.raw)::numeric AS divergence
    FROM resp rt
    JOIN resp src
      ON src.item_number = rt.retest_of_item_number
     AND src.the_trait = rt.the_trait
    WHERE rt.retest_of_item_number IS NOT NULL
  ),
  by_trait_retest AS (
    SELECT the_trait,
           count(*)::int AS n_pairs,
           round(avg(divergence), 2) AS mean_divergence
    FROM retest_pairs
    GROUP BY the_trait
  )
  SELECT bt.the_trait,
         bt.n,
         CASE WHEN bt.sd IS NULL THEN NULL ELSE round(bt.sd, 2) END,
         COALESCE(btr.n_pairs, 0),
         btr.mean_divergence
  FROM by_trait bt
  LEFT JOIN by_trait_retest btr ON btr.the_trait = bt.the_trait
  ORDER BY bt.the_trait;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- compute_newtworks_v1_reliability_population
-- Classical Cronbach's alpha + Spearman-Brown split-half across all agency v1
-- candidates. Retest items excluded (they'd double-weight source items).
-- Returns NULL below p_min_n candidates; today with N=2, all rows return NULL.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_reliability_population(
  p_agency_id uuid,
  p_min_n integer DEFAULT 10
)
RETURNS TABLE(
  trait text,
  n_candidates integer,
  n_items_in_trait integer,
  cronbach_alpha numeric,
  spearman_brown_split_half numeric
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  trait_row RECORD;
  v_n_cand int;
  v_k int;               -- item count
  v_alpha numeric;
  v_split numeric;
  v_odd_sums numeric[];
  v_even_sums numeric[];
BEGIN
  FOR trait_row IN
    SELECT DISTINCT i.hypothesized_trait AS the_trait
    FROM public.hiregauge_instrument_items i
    WHERE i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND i.is_active
      AND i.retest_of_item_number IS NULL  -- exclude retest items to avoid double-weighting
    ORDER BY 1
  LOOP
    -- Cronbach's alpha: k / (k-1) * (1 - sum(item_variances) / total_variance)
    -- Where total = sum of all items per candidate. All computed across candidates.
    DECLARE
      candidate_totals numeric[];
      item_variances numeric[] := ARRAY[]::numeric[];
      var_total numeric;
      sum_item_var numeric := 0;
    BEGIN
      -- Per-candidate total score for this trait (polarity-flipped)
      WITH per_cand_totals AS (
        SELECT r.candidate_id, sum(
          CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END
        )::numeric AS total_score,
        count(*) AS k_answered
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        JOIN public.hiring_candidates c ON c.id = r.candidate_id
        WHERE c.agency_id = p_agency_id
          AND i.section = 'newtworks_v1_personality'
          AND i.hypothesized_trait = trait_row.the_trait
          AND i.is_active
          AND i.retest_of_item_number IS NULL
          AND r.response_value IS NOT NULL
        GROUP BY r.candidate_id
      )
      SELECT count(*)::int, array_agg(total_score)
      INTO v_n_cand, candidate_totals
      FROM per_cand_totals;

      -- Item count (max k answered by any candidate — approximation; assumes items are consistent across candidates)
      SELECT count(*)::int INTO v_k
      FROM public.hiregauge_instrument_items i
      WHERE i.section = 'newtworks_v1_personality'
        AND i.hypothesized_trait = trait_row.the_trait
        AND i.is_active
        AND i.retest_of_item_number IS NULL;

      IF v_n_cand < p_min_n OR v_k < 2 THEN
        RETURN QUERY SELECT trait_row.the_trait, v_n_cand, v_k, NULL::numeric, NULL::numeric;
        CONTINUE;
      END IF;

      -- Per-item variance across candidates
      SELECT array_agg(item_var) INTO item_variances FROM (
        SELECT var_samp(
          CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END
        )::numeric AS item_var
        FROM public.hiregauge_instrument_items i
        JOIN public.hiregauge_candidate_responses r ON r.item_id = i.id
        JOIN public.hiring_candidates c ON c.id = r.candidate_id
        WHERE c.agency_id = p_agency_id
          AND i.section = 'newtworks_v1_personality'
          AND i.hypothesized_trait = trait_row.the_trait
          AND i.is_active
          AND i.retest_of_item_number IS NULL
          AND r.response_value IS NOT NULL
        GROUP BY i.id
      ) item_vars;

      IF item_variances IS NULL THEN
        v_alpha := NULL;
      ELSE
        SELECT COALESCE(sum(COALESCE(x, 0)), 0) INTO sum_item_var FROM unnest(item_variances) AS t(x);
        SELECT var_samp(x) INTO var_total FROM unnest(candidate_totals) AS t(x);
        IF var_total IS NULL OR var_total = 0 THEN
          v_alpha := NULL;
        ELSE
          v_alpha := (v_k::numeric / (v_k - 1)) * (1 - sum_item_var / var_total);
          -- Clamp to [-1, 1]
          v_alpha := GREATEST(-1, LEAST(1, v_alpha));
        END IF;
      END IF;

      -- Split-half via Spearman-Brown: split trait's items into odd/even by
      -- item_number, compute per-candidate half-sums, correlate the two halves,
      -- apply Spearman-Brown to project full-length reliability.
      WITH per_cand_halves AS (
        SELECT r.candidate_id,
               sum(CASE WHEN i.item_number % 2 = 1 THEN
                   CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END
                   ELSE 0 END)::numeric AS odd_sum,
               sum(CASE WHEN i.item_number % 2 = 0 THEN
                   CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END
                   ELSE 0 END)::numeric AS even_sum,
               count(*) FILTER (WHERE i.item_number % 2 = 1) AS n_odd,
               count(*) FILTER (WHERE i.item_number % 2 = 0) AS n_even
        FROM public.hiregauge_instrument_items i
        JOIN public.hiregauge_candidate_responses r ON r.item_id = i.id
        JOIN public.hiring_candidates c ON c.id = r.candidate_id
        WHERE c.agency_id = p_agency_id
          AND i.section = 'newtworks_v1_personality'
          AND i.hypothesized_trait = trait_row.the_trait
          AND i.is_active
          AND i.retest_of_item_number IS NULL
          AND r.response_value IS NOT NULL
        GROUP BY r.candidate_id
        HAVING count(*) FILTER (WHERE i.item_number % 2 = 1) > 0
           AND count(*) FILTER (WHERE i.item_number % 2 = 0) > 0
      ),
      corr AS (
        SELECT corr(odd_sum, even_sum) AS r_half FROM per_cand_halves
      )
      SELECT r_half INTO v_split FROM corr;
      IF v_split IS NULL THEN
        -- keep NULL
      ELSE
        v_split := GREATEST(-1, LEAST(1, v_split));
        IF v_split IS NOT NULL AND v_split > -1 THEN
          v_split := (2 * v_split) / (1 + v_split);
          v_split := GREATEST(-1, LEAST(1, v_split));
        END IF;
      END IF;

      RETURN QUERY SELECT trait_row.the_trait, v_n_cand, v_k,
        CASE WHEN v_alpha IS NULL THEN NULL ELSE round(v_alpha, 2) END,
        CASE WHEN v_split IS NULL THEN NULL ELSE round(v_split, 2) END;
    END;
  END LOOP;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- compute_newtworks_v1_traits_as_row — add reliability_by_trait to the return.
-- ROW-shape change requires DROP + CREATE. Callers: hiregauge_evaluate_candidate
-- v3 archetype path + CandidateDetail.jsx (RPC name only, unaffected by cols).
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
  reliability_by_trait jsonb
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
    reliability_json;
END;
$function$;
