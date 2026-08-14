-- COMMON-SCALE FIX (Peter approval 2026-08-14, conditional on peer-reviewed backing):
-- gma and sjt entered the role-fit weighted sum as raw percent-correct / raw 0-100
-- score while the other 25 inputs are population-referenced percentiles. Mixing scales
-- in one weighted sum violates the unit-weighting basis the engine itself cites
-- (Wainer 1976 Psych Bull 83:213-217; Dawes 1979 Am Psychologist 34:571-582 -- both
-- operate on STANDARDIZED predictors), and raw scores carry no interpretation without
-- a norm reference (Nunnally & Bernstein 1994, Psychometric Theory 3rd ed., norms;
-- AERA/APA/NCME Standards for Educational and Psychological Testing 2014). Observed
-- effect: applicant-pool gma percent-correct runs 63-94 (mean 80.7) and sjt 0-100
-- (mean 86.0) against facet percentiles centered at 50 by construction -- every
-- candidate's "hard" evidence read high, discrimination was compressed on exactly the
-- inputs that absorb weight when protocol validity drops, and the seat bands
-- (authored as percentile concepts) barely filtered.
--
-- Fix: local applicant-pool norms for 'gma' and 'sjt' in hiregauge_facet_norms; both
-- inputs now route through the SAME hiregauge_facet_percentile transform as the other
-- 25 (single transform function, zero new per-row cost). Rank-order interpretation
-- within the applicant pool is the standard selection frame (Schmidt & Hunter 1998
-- Psych Bull 124:262-274).
--
-- Honest caveats, recorded here and in the function docstring:
-- (1) n=31 local norms are coarse; refresh at the N>=50 recalibration checkpoint
--     (recompute mean/sd, update the two norm rows).
-- (2) GMA percent-correct is computed over adaptively served item subsets; percent
--     over different subsets is an approximation of ability. Item-response-theory
--     scoring over the 75-item bank is the eventual upgrade path.
-- (3) The reasoning-floor gate (_newtworks_reasoning_gate) intentionally stays on
--     percent-correct: its 62.5 threshold is an ABSOLUTE better-than-chance check
--     (chance + 2 SD), a different job than relative standing. Do not convert it.

INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'gma', 80.68, 8.72,
   'newtworks_v2 cognitive section, percent-correct over live scoreable items answered',
   'Local applicant-pool norm (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014)',
   'computed from 31 completed v2 assessments, 2026-08-14',
   'REFRESH AT N>=50: recompute mean/sd over completed v2 pool. Percent-correct over adaptive item subsets is approximate; IRT scoring is the upgrade path.',
   now(), 'claude_migration'),
  ('126794dd-25ff-47d2-a436-724499733365', 'sjt', 86.02, 12.80,
   'newtworks_v2 situational judgment score, 0-100',
   'Local applicant-pool norm (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014)',
   'computed from 31 completed v2 assessments, 2026-08-14',
   'REFRESH AT N>=50: recompute mean/sd over completed v2 pool.',
   now(), 'claude_migration')
ON CONFLICT (agency_id, facet) DO UPDATE
SET ref_mean_0_100 = EXCLUDED.ref_mean_0_100,
    ref_sd_0_100   = EXCLUDED.ref_sd_0_100,
    source_scale   = EXCLUDED.source_scale,
    citation       = EXCLUDED.citation,
    retrieved_from = EXCLUDED.retrieved_from,
    notes          = EXCLUDED.notes,
    updated_at     = now(),
    updated_by     = 'claude_migration';

CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_2_pool_normed_cognitive_2026_08_14

Facet-direct role-fit core. Direct weighted sum over 27 inputs -- 25
personality/goal-orientation facets as percentiles against published norms
in hiregauge_facet_norms, plus gma and sjt as percentiles against LOCAL
APPLICANT-POOL norms in the same table -- using per-role weights from
hiregauge_role_facet_weights.

COMMON-SCALE RULE (added 2026-08-14, role_fit_v5_2): all 27 inputs enter
the weighted sum on a percentile scale via the single transform
hiregauge_facet_percentile. The unit-weighting literature this engine is
built on assumes standardized predictors (Wainer 1976 Psych Bull
83:213-217; Dawes 1979 Am Psychologist 34:571-582); raw scores have no
meaning without a norm reference (Nunnally & Bernstein 1994; AERA/APA/NCME
Standards 2014); within-pool rank order is the selection frame (Schmidt &
Hunter 1998 Psych Bull 124:262-274). gma/sjt local norms: n=31 pool,
refresh at N>=50; percent-correct over adaptive item subsets approximates
ability -- IRT over the 75-item bank is the upgrade path. Band edges in
hiregauge_role_ideal_ranges compare against these pool percentiles (their
original percentile intent). The reasoning-floor gate intentionally stays
on raw percent-correct (absolute chance+2SD check) -- do not convert it.

VALIDITY-CONDITIONED WEIGHTING (added 2026-08-13, role_fit_v5_1): the 25
self-report facet inputs have their weight scaled by protocol validity v
(see _newtworks_protocol_validity) before entering the weighted sum. gma
and sjt weights are never scaled by v -- they are the harder-to-fake,
contextualized measures that absorb the shifted weight via the existing
renormalization (denominator = sum of effective positive weights over
non-NULL inputs). This is evidence weighting of the self-report layer, not
individual score correction -- stored candidate values are never altered.
See _newtworks_protocol_validity for full citation list (Mueller-Hanson,
Heggestad & Thornton 2003; Komar, Brown, Komar & Robie 2008; Ellingson,
Sackett & Hough 1999; Meade & Craig 2012).

Design grounding:
- Synthetic/composite validity over single-predictor validity: Lawshe 1952;
  Scherbaum 2005 Pers Psych 58:481-515; Johnson & Carter 2010 Pers Psych 63.
- Equal/unit weighting competitive with regression weighting under
  real-world noise: Wainer 1976; Dawes 1979.
- Facet-level (vs domain-level) prediction: Dudley, Orvis, Lebiecki &
  Cortina 2006 JAP 91:40-57.
- Two non-linear ceiling folds (assertiveness/sales_outbound,
  cautiousness/retention_reception+retention_support): Grant 2013 Psych Sci
  24:1024-1030 (GR13); Le, Oh, Robbins, Ilies, Holland & Westrick 2011 JAP
  96:113-133 (LE11). No other ceiling folds exist -- do not add more.
- Norms-referencing approach: Johnson 2014 J Res Pers 51:78-89.

GMA input: percent-correct uses the LIVE count of scoreable GMA items this
candidate answered (hiregauge_candidate_responses joined to
hiregauge_instrument_items, section='newtworks_v2_cognitive_gma',
cognitive_domain IS NOT NULL, retest_of_item_number IS NULL) -- same filter
as apply_newtworks_gma_to_candidate, same population on both sides of the
division. Never a hardcoded item-bank size (hiregauge_v2_normalized_inputs'
docstring records a hardcoded 16 producing >100% scores once the item bank
grew past that count while three stray items were live at stint 2; the bank
now holds 75 scoreable items under adaptive serving). The percent is then
pool-percentiled via hiregauge_facet_percentile('gma'); raw percent kept in
the input detail as raw_0_100.

SJT input: sjt_score pool-percentiled via hiregauge_facet_percentile('sjt');
raw kept in the input detail as raw_0_100.

Fit formula: fit = clamp( SUM(effective_weight_i * effective_value_i) /
SUM(effective_weight_i WHERE effective_weight_i > 0 AND value_i IS NOT
NULL), 0, 100 ). effective_weight_i = weight_i for gma/sjt, weight_i * v
for the 25 self-report facets. A NULL-valued input (no percentile norm,
e.g. the deliberately-parked competitiveness facet, or a raw score the
candidate never produced) is excluded from both the numerator and the
positive-weight denominator, and listed in missing_inputs. Negative-weight
inputs (e.g. anger) subtract in the numerator without inflating the
denominator.
*/
DECLARE
  v_input_names text[] := ARRAY[
    'achievement_striving','self_discipline','emotional_stability','dutifulness',
    'customer_orientation','self_efficacy','proactive_personality','cautiousness',
    'anxiety','friendliness','anger','cooperation','trust','dispositional_optimism',
    'political_skill_networking','enterprising','sincerity','fairness','greed_avoidance',
    'assertiveness','compassion','competitiveness','learning_goal_orientation',
    'prove_goal_orientation','avoid_goal_orientation','gma','sjt'
  ];
  v_candidate_json jsonb;
  v_name text;
  v_raw numeric;
  v_value numeric;
  v_eff numeric;
  v_weight numeric;
  v_eff_weight numeric;
  v_citation text;
  v_gma_n numeric;
  v_raw_0_100 numeric;
  v_weighted_sum numeric := 0;
  v_denom numeric := 0;
  v_detail jsonb := '{}'::jsonb;
  v_missing text[] := ARRAY[]::text[];
  v_fit numeric;
  v_validity jsonb;
  v_v numeric;
BEGIN
  IF p_candidate.achievement_striving IS NULL THEN
    RETURN jsonb_build_object('error', 'no_trait_data', 'role_category', p_role_category);
  END IF;

  v_candidate_json := to_jsonb(p_candidate);
  v_validity := public._newtworks_protocol_validity(p_candidate);
  v_v := (v_validity->>'v')::numeric;

  FOREACH v_name IN ARRAY v_input_names LOOP
    SELECT weight, citation INTO v_weight, v_citation
      FROM public.hiregauge_role_facet_weights
      WHERE agency_id = p_candidate.agency_id
        AND role_category = p_role_category
        AND input_name = v_name;
    v_weight := COALESCE(v_weight, 0);

    IF v_name IN ('gma','sjt') THEN
      v_eff_weight := v_weight;
    ELSE
      v_eff_weight := v_weight * v_v;
    END IF;

    v_raw_0_100 := NULL;

    IF v_name = 'gma' THEN
      SELECT count(*)::numeric INTO v_gma_n
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL;
      v_raw_0_100 := CASE
        WHEN p_candidate.gma_total_accuracy IS NULL OR COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE ROUND(p_candidate.gma_total_accuracy::numeric / v_gma_n * 100.0)
      END;
      v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, 'gma', v_raw_0_100);
    ELSIF v_name = 'sjt' THEN
      v_raw_0_100 := p_candidate.sjt_score;
      v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, 'sjt', v_raw_0_100);
    ELSE
      v_raw := (v_candidate_json->>v_name)::numeric;
      IF v_raw IS NULL THEN
        v_value := NULL;
      ELSE
        v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, v_name, v_raw);
      END IF;
    END IF;

    IF v_value IS NULL THEN
      v_missing := array_append(v_missing, v_name);
      v_detail := v_detail || jsonb_build_object(v_name, jsonb_build_object(
        'value', NULL, 'effective', NULL, 'weight', v_weight, 'effective_weight', v_eff_weight, 'basis', v_citation));
      CONTINUE;
    END IF;

    v_eff := v_value;
    IF p_role_category = 'sales_outbound' AND v_name = 'assertiveness' AND v_eff > 75 THEN
      v_eff := 75 - (v_eff - 75) * 0.5;
    ELSIF p_role_category IN ('retention_reception','retention_support') AND v_name = 'cautiousness' AND v_eff > 80 THEN
      v_eff := 80 - (v_eff - 80) * 0.5;
    END IF;

    v_detail := v_detail || jsonb_build_object(v_name, jsonb_build_object(
      'value', v_value, 'effective', v_eff, 'weight', v_weight, 'effective_weight', v_eff_weight,
      'basis', v_citation)
      || CASE WHEN v_name IN ('gma','sjt')
              THEN jsonb_build_object('raw_0_100', v_raw_0_100)
              ELSE '{}'::jsonb END);

    v_weighted_sum := v_weighted_sum + v_eff_weight * v_eff;
    IF v_eff_weight > 0 THEN
      v_denom := v_denom + v_eff_weight;
    END IF;
  END LOOP;

  IF v_denom = 0 THEN
    v_fit := NULL;
  ELSE
    v_fit := GREATEST(0, LEAST(100, v_weighted_sum / v_denom));
  END IF;

  RETURN jsonb_build_object(
    'role_category', p_role_category,
    'fit_score', ROUND(v_fit, 1),
    'inputs', v_detail,
    'missing_inputs', to_jsonb(v_missing),
    'protocol_validity', v_validity
  );
END;
$function$;
