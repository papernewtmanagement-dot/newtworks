-- Newtworks v1 Stint 2 build, step 9 of 10 per handoff 2026-07-28.
--
-- Extends the v1 scoring stack:
--   1. compute_newtworks_v1_traits: adds optional p_stint + p_sitting
--      filters. Passing NULL to either means "no filter on that axis."
--      p_stint NULL + p_sitting NULL = merge every response ever submitted,
--      which is the desired default for a candidate who has completed
--      stint 2 expansion (handoff: "auto-merge stint 1+2 when both present").
--   2. Adds four new helper scoring functions covering the validity
--      signals wired to the step 8 expansion_triggers table:
--        - compute_newtworks_v1_cognitive_score       (% correct on v1 items)
--        - compute_newtworks_v1_impression_mgmt_score (IM Likert 0-100)
--        - compute_newtworks_v1_nonsense_inflation    (# fake words endorsed)
--        - compute_newtworks_v1_retest_divergence     (avg |diff| on retest pairs)
--   3. Adds compute_newtworks_v1_expansion_triggers which reads the
--      hiregauge_expansion_triggers table and returns the JSON list of
--      rules that fire on the passed signals.
--   4. compute_newtworks_v1_traits_as_row: rewritten to compose all of the
--      above. Returns one row per candidate covering 9 traits, overall
--      score, validity signals, and fired-trigger JSON.
--
-- Consumer audit 2026-07-28 confirmed zero callers (0 DB, 0 frontend).
-- Signatures change freely; new shape is the design target for the step 10
-- frontend form to consume.
--
-- Cognitive score note: section='cognitive' contains both CTS legacy items
-- (stint IS NULL, being retired) and v1 additions (stint IN (1,2)). The v1
-- scoring filters by "stint IS NOT NULL" to keep legacy items out until
-- Peter flips them to is_active=false. If CTS items ever get stint tags in
-- the future, revise the filter.

DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits(uuid);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits_as_row(uuid);

-- ============================================================================
-- 1. Long-form personality trait scoring with optional stint/sitting filters
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(
  trait text,
  n_items int,
  raw_avg numeric,
  score_0_100 int
)
LANGUAGE sql
STABLE
AS $$
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
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_traits IS
  'Newtworks v1 personality trait scoring. Reads responses to section=newtworks_v1_personality items, applies reverse-coded flip using each item scale_max, rescales avg to 0-100. Returns one row per trait. Optional p_stint (NULL=any) and p_sitting (NULL=all merged) filters.';

-- ============================================================================
-- 2. Cognitive score — percentage correct on v1 cognitive items
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_cognitive_score(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(score_0_100 int, n_items int)
LANGUAGE sql
STABLE
AS $$
  WITH scored AS (
    SELECT (r.response_label = i.answer_key)::int AS is_correct
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'cognitive'
      AND i.stint IS NOT NULL  -- v1 additions only; CTS legacy has stint=NULL
      AND i.is_active
      AND r.response_label IS NOT NULL
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  )
  SELECT round(avg(is_correct) * 100)::int AS score_0_100,
         count(*)::int AS n_items
  FROM scored;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_cognitive_score IS
  'Newtworks v1 cognitive scoring — percentage-correct on v1 cognitive items (section=cognitive, stint IS NOT NULL). Feeds the borderline_cognitive expansion trigger (fires at 40-60).';

-- ============================================================================
-- 3. Impression management score — Likert 0-100 with reverse coding
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_impression_mgmt_score(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(score_0_100 int, n_items int)
LANGUAGE sql
STABLE
AS $$
  WITH scored AS (
    SELECT CASE
             WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value
             ELSE r.response_value
           END AS adj,
           i.scale_max
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_impression_mgmt'
      AND i.is_active
      AND r.response_value IS NOT NULL
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  )
  SELECT round(((avg(adj) - 1) / (max(scale_max) - 1) * 100)::numeric)::int AS score_0_100,
         count(*)::int AS n_items
  FROM scored;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_impression_mgmt_score IS
  'Newtworks v1 impression-management validity score — Likert 0-100 with reverse-code flip on -keyed items. High score => candidate is dressing up their answers. Feeds the elevated_impression_mgmt trigger (fires at >=70).';

-- ============================================================================
-- 4. Nonsense inflation — count of fake vocab items endorsed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_nonsense_inflation(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(inflation_count int, n_nonsense_items int)
LANGUAGE sql
STABLE
AS $$
  WITH scored AS (
    SELECT (r.response_label IS NOT NULL AND r.response_label <> i.answer_key)::int AS inflated
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_vct'
      AND i.is_nonsense = true
      AND i.is_active
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
  )
  SELECT COALESCE(sum(inflated), 0)::int AS inflation_count,
         count(*)::int AS n_nonsense_items
  FROM scored;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_nonsense_inflation IS
  'Newtworks v1 nonsense-inflation count — number of fake vocab items where candidate picked a fabricated definition instead of "None of these." Feeds the nonsense_inflation trigger (fires at >=2).';

-- ============================================================================
-- 5. Retest divergence — mean |diff| across retest_of_item_number pairs
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_retest_divergence(
  p_candidate_id uuid,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(avg_divergence numeric, n_pairs int)
LANGUAGE sql
STABLE
AS $$
  WITH pairs AS (
    SELECT abs(r_retest.response_value - r_source.response_value)::numeric AS divergence
    FROM public.hiregauge_instrument_items i_retest
    JOIN public.hiregauge_instrument_items i_source
      ON i_source.section = i_retest.section
     AND i_source.item_number = i_retest.retest_of_item_number
    JOIN public.hiregauge_candidate_responses r_retest
      ON r_retest.item_id = i_retest.id AND r_retest.candidate_id = p_candidate_id
    JOIN public.hiregauge_candidate_responses r_source
      ON r_source.item_id = i_source.id AND r_source.candidate_id = p_candidate_id
    WHERE i_retest.retest_of_item_number IS NOT NULL
      AND i_retest.is_active
      AND r_retest.response_value IS NOT NULL
      AND r_source.response_value IS NOT NULL
      AND (p_sitting IS NULL OR (r_retest.sitting = p_sitting AND r_source.sitting = p_sitting))
  )
  SELECT round(avg(divergence), 2) AS avg_divergence,
         count(*)::int AS n_pairs
  FROM pairs;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_retest_divergence IS
  'Newtworks v1 retest reliability signal — mean absolute Likert-scale difference between retest duplicate items and their originals. Feeds the retest_divergence_high trigger (fires at >2).';

-- ============================================================================
-- 6. Expansion trigger dispatcher
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_expansion_triggers(
  p_agency_id uuid,
  p_trait_scores jsonb,
  p_cognitive_score int,
  p_impression_mgmt_score int,
  p_nonsense_inflation int,
  p_retest_divergence numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  fired jsonb := '[]'::jsonb;
  rule RECORD;
  signal_value numeric;
BEGIN
  FOR rule IN
    SELECT *
    FROM public.hiregauge_expansion_triggers
    WHERE agency_id = p_agency_id AND is_active = true
    ORDER BY signal_type, trigger_name
  LOOP
    signal_value := CASE rule.signal_type
      WHEN 'trait_score' THEN
        CASE WHEN p_trait_scores ? rule.signal_trait
             THEN (p_trait_scores ->> rule.signal_trait)::numeric
             ELSE NULL END
      WHEN 'section_score' THEN
        CASE rule.signal_section
          WHEN 'cognitive' THEN p_cognitive_score::numeric
          ELSE NULL
        END
      WHEN 'impression_mgmt_score' THEN p_impression_mgmt_score::numeric
      WHEN 'nonsense_inflation'    THEN p_nonsense_inflation::numeric
      WHEN 'retest_divergence'     THEN p_retest_divergence
    END;

    IF signal_value IS NULL THEN
      CONTINUE;
    END IF;

    IF (rule.low_bound  IS NULL OR signal_value >= rule.low_bound)
       AND (rule.high_bound IS NULL OR signal_value <= rule.high_bound) THEN
      fired := fired || jsonb_build_array(jsonb_build_object(
        'trigger_name',      rule.trigger_name,
        'signal_type',       rule.signal_type,
        'signal_trait',      rule.signal_trait,
        'signal_section',    rule.signal_section,
        'signal_value',      signal_value,
        'action',            rule.action,
        'expansion_section', rule.expansion_section,
        'expansion_trait',   rule.expansion_trait,
        'expansion_count',   rule.expansion_count
      ));
    END IF;
  END LOOP;

  RETURN fired;
END;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_expansion_triggers IS
  'Newtworks v1 expansion trigger dispatcher — reads hiregauge_expansion_triggers rows for the agency, evaluates each against the passed signal values, and returns the JSON list of rules that fire. Called by compute_newtworks_v1_traits_as_row.';

-- ============================================================================
-- 7. Wide-form scoring — one row per candidate covering everything
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits_as_row(
  p_candidate_id uuid,
  p_stint int DEFAULT NULL,
  p_sitting int DEFAULT NULL
)
RETURNS TABLE(
  candidate_id uuid,
  -- 9 personality traits
  assertiveness int,
  independent_spirit int,
  compassion int,
  belief_in_others int,
  optimism int,
  analytical int,
  deadline_motivation int,
  self_promotion int,
  recognition_drive int,
  overall_score int,
  n_items_scored int,
  -- validity + cognitive
  cognitive_score int,
  cognitive_n int,
  impression_mgmt_score int,
  impression_mgmt_n int,
  nonsense_inflation int,
  nonsense_n int,
  retest_divergence numeric,
  retest_n_pairs int,
  -- fired triggers
  expansion_triggers jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
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
    triggers;
END;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_traits_as_row IS
  'Newtworks v1 scoring wrapper — one row per candidate covering all v1 signals: 9 personality traits, overall score, cognitive score, impression management score, nonsense inflation, retest divergence, and the JSON list of expansion_triggers that fire on the current scores. Optional p_stint and p_sitting filters (both NULL = merge every response). This is the frontend one-stop-shop call.';
