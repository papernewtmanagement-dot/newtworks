CREATE OR REPLACE FUNCTION public.interview_candidate_triggers(p_candidate_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_codes text[] := ARRAY[]::text[];
  v_gma_n numeric;
  v_gma_pct numeric;
  v_resume jsonb;
  v_honesty numeric;
  v_follow_through numeric;
  v_trajectory numeric;
  v_coherent_pursuit numeric;
  v_personal_responsibility numeric;
  v_text_lower text;
  v_res_commit numeric;
  v_asm_commit numeric;
  v_res_char numeric;
  v_asm_char numeric;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN v_codes;
  END IF;

  -- ===== New-instrument path (achievement_striving IS NOT NULL) =====
  IF v_row.achievement_striving IS NOT NULL THEN
    IF v_row.impression_management_band = 'elevated' THEN
      v_codes := array_append(v_codes, 'T_IM_ELEVATED');
    END IF;
    IF v_row.integrity_flag IS TRUE OR v_row.integrity_gate_shadow_result = 'fail' THEN
      v_codes := array_append(v_codes, 'T_INTEGRITY_FLAG');
    END IF;
    IF v_row.churn_risk IS TRUE THEN
      v_codes := array_append(v_codes, 'T_CHURN_RISK');
    END IF;

    IF v_row.gma_total_accuracy IS NOT NULL THEN
      SELECT count(*)::numeric INTO v_gma_n
      FROM public.hiregauge_candidate_responses r
      JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
      WHERE r.candidate_id = p_candidate_id
        AND i.section = 'newtworks_v2_cognitive_gma'
        AND i.cognitive_domain IS NOT NULL
        AND i.retest_of_item_number IS NULL;

      IF COALESCE(v_gma_n, 0) > 0 THEN
        v_gma_pct := v_row.gma_total_accuracy::numeric / v_gma_n;
        IF v_gma_pct < 0.50 THEN
          v_codes := array_append(v_codes, 'T_GMA_LOW');
        END IF;
      END IF;
    END IF;

    IF v_row.sjt_score IS NOT NULL AND v_row.sjt_score < 50 THEN
      v_codes := array_append(v_codes, 'T_SJT_LOW');
    END IF;
    IF v_row.self_discipline IS NOT NULL AND v_row.self_discipline < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_SELF_DISCIPLINE');
    END IF;
    IF v_row.achievement_striving IS NOT NULL AND v_row.achievement_striving < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ACHIEVEMENT');
    END IF;
    IF v_row.dutifulness IS NOT NULL AND v_row.dutifulness < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_DUTIFULNESS');
    END IF;
    IF v_row.emotional_stability IS NOT NULL AND v_row.emotional_stability < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_EMOTIONAL_STABILITY');
    END IF;
    IF v_row.assertiveness IS NOT NULL AND v_row.assertiveness < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ASSERTIVENESS_V2');
    END IF;
    IF v_row.compassion IS NOT NULL AND v_row.compassion < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_COMPASSION_V2');
    END IF;
    IF v_row.cooperation IS NOT NULL AND v_row.cooperation < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_COOPERATION');
    END IF;
    IF v_row.customer_orientation IS NOT NULL AND v_row.customer_orientation < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_CUSTOMER_ORIENTATION');
    END IF;
    IF v_row.proactive_personality IS NOT NULL AND v_row.proactive_personality < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_PROACTIVE');
    END IF;
    IF v_row.enterprising IS NOT NULL AND v_row.enterprising < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_ENTERPRISING');
    END IF;
    IF v_row.avoid_goal_orientation IS NOT NULL AND v_row.avoid_goal_orientation > 70 THEN
      v_codes := array_append(v_codes, 'T_AVOID_GOAL_HIGH');
    END IF;
    IF v_row.self_efficacy IS NOT NULL AND v_row.self_efficacy < 40 THEN
      v_codes := array_append(v_codes, 'T_LOW_SELF_EFFICACY');
    END IF;
    IF v_row.cautiousness IS NOT NULL AND v_row.cautiousness > 75 THEN
      v_codes := array_append(v_codes, 'T_HIGH_CAUTIOUSNESS');
    END IF;
  END IF;

  -- ===== Validity trigger (either path) =====
  IF v_row.reliability IN ('moderate','low') OR v_row.response_distortion IN ('moderate','high') THEN
    v_codes := array_append(v_codes, 'L_VALIDITY');
  END IF;

  -- ===== Resume-vs-assessment gap triggers (either path) =====
  SELECT res_commitment, assessment_commitment, res_character, assessment_character
    INTO v_res_commit, v_asm_commit, v_res_char, v_asm_char
  FROM public.v_hiring_candidates
  WHERE id = p_candidate_id;

  IF v_res_commit IS NOT NULL AND v_asm_commit IS NOT NULL
     AND abs(v_res_commit - v_asm_commit) >= 25 THEN
    v_codes := array_append(v_codes, 'T_GAP_COMMITMENT');
  END IF;
  IF v_res_char IS NOT NULL AND v_asm_char IS NOT NULL
     AND abs(v_res_char - v_asm_char) >= 25 THEN
    v_codes := array_append(v_codes, 'T_GAP_CHARACTER');
  END IF;

  -- ===== Resume-only triggers (fire regardless of path) =====
  v_resume := v_row.resume_analysis;
  IF v_resume IS NOT NULL AND v_resume ? 'signals' THEN
    v_honesty := NULLIF(v_resume #>> '{signals,honesty,score}', '')::numeric;
    v_follow_through := NULLIF(v_resume #>> '{signals,follow_through,score}', '')::numeric;
    v_trajectory := NULLIF(v_resume #>> '{signals,trajectory_direction,score}', '')::numeric;
    v_coherent_pursuit := NULLIF(v_resume #>> '{signals,coherent_pursuit,score}', '')::numeric;
    v_personal_responsibility := NULLIF(v_resume #>> '{signals,personal_responsibility,score}', '')::numeric;

    IF v_honesty IS NOT NULL AND v_honesty < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_HONESTY_LOW');
    END IF;
    IF v_follow_through IS NOT NULL AND v_follow_through < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_FOLLOW_THROUGH_LOW');
    END IF;
    IF v_trajectory IS NOT NULL AND v_trajectory < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_TRAJECTORY_LOW');
    END IF;
    IF v_coherent_pursuit IS NOT NULL AND v_coherent_pursuit < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_COHERENT_PURSUIT_LOW');
    END IF;
    IF v_personal_responsibility IS NOT NULL AND v_personal_responsibility < 40 THEN
      v_codes := array_append(v_codes, 'T_RES_RESPONSIBILITY_LOW');
    END IF;

    IF v_row.resume_extracted_text IS NOT NULL THEN
      v_text_lower := lower(v_row.resume_extracted_text);

      IF v_text_lower NOT LIKE '%sales%'
         AND v_text_lower NOT LIKE '%account executive%'
         AND v_text_lower NOT LIKE '%producer%'
      THEN
        v_codes := array_append(v_codes, 'T_RES_NO_SALES_HISTORY');
      END IF;

      IF v_text_lower LIKE '%led %' OR v_text_lower LIKE '%managed %' OR v_text_lower LIKE '%supervised %' THEN
        v_codes := array_append(v_codes, 'T_RES_LEADERSHIP_CLAIM');
      END IF;

      IF (v_text_lower LIKE '%\%%' OR v_text_lower LIKE '%$%')
         AND (v_text_lower LIKE '%sale%' OR v_text_lower LIKE '%sold%' OR v_text_lower LIKE '%revenue%' OR v_text_lower LIKE '%quota%')
         AND v_honesty IS NOT NULL AND v_honesty < 60
      THEN
        v_codes := array_append(v_codes, 'T_SALES_CLAIM_UNSUPPORTED');
      END IF;
    END IF;
  END IF;

  SELECT array_agg(DISTINCT c) INTO v_codes FROM unnest(v_codes) AS c;
  RETURN COALESCE(v_codes, ARRAY[]::text[]);
END;
$function$
CREATE OR REPLACE FUNCTION public._newtworks_integrity_decline_gate(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
-- SHADOW MODE per Peter directive 2026-08-03. This gate NEVER hard-declines
-- live -- integrity self-report validity is contested, not settled (Ones,
-- Viswesvaran & Schmidt 1993: .41 vs supervisor ratings, 665 coefficients;
-- Van Iddekinge, Roth, Raymark & Odle-Dusseau 2012 JAP 97(3) 499-530 redid
-- it and got .15/.18 corrected; three rebuttals + Sackett & Schmitt 2012 JAP
-- 97(3) 550-556 in the same issue, unresolved). Their own moderators point
-- the wrong way for a homemade instrument scored against future real
-- outcomes: .27 publisher-authored vs .12 non-publisher; .42 self-reported
-- misconduct vs .11 other-reported / .15 employment-record misconduct. Our
-- three self-report facets (sincerity, fairness, greed_avoidance) are also
-- the most-faked item type in selection -- applicant scores compress near
-- the top, so low scorers are disproportionately the candid and the
-- careless, not the dishonest.
--
-- ARCHITECTURE: compares the RAW (undampened) self-report composite to the
-- floor -- never a dampened or reliability-shrunk 'adjusted' value.
-- Ellingson, Sackett & Hough 1999 (JAP 84 155-166): social-
-- desirability corrections do not recover an individual's honest score --
-- later reviews found they work at group level but not individual level and
-- do not improve prediction. Raw values are the only permitted input to
-- this gate -- never a dampened or adjusted display value.
--
-- CONJUNCTIVE GATE -- all four conditions required for even the shadow
-- "would decline" record:
--   1. RAW self-report composite (mean of sincerity/fairness/greed_avoidance, no dampening or shrinkage
--      applied) < 40.
--   2. sjt_honesty_integrity component below its own floor -- the
--      contextualised scenario measure, hardest to fake, and per Sackett et
--      al. 2022 contextualised measures show far more stable validity than
--      decontextualised self-report. Floor set at 50% (2 of 4 items) --
--      PROVISIONAL, a build-session judgment call (no published norms exist
--      for a homemade 4-item scenario set), watch and revisit alongside the
--      raw-composite floor at N=25-30.
--   3. Careless-responding / reliability check CLEAN (reliability='high' AND
--      zero methods fired). A low score from a careless responder is a
--      measurement failure, not a red flag -- goes to human review, not this
--      gate.
--   4. Faking-good NOT flagged (impression_management_band='typical'). A
--      detected faker's low score is also a measurement failure, not a red
--      flag.
--
-- LIVE BEHAVIOUR (the only thing this gate does today): when all four
-- conditions hold, cap verdict at 'consider' + set a visible integrity flag
-- -- same soft treatment as a critical-floor breach. Never an auto-decline.
-- 'fired' stays permanently false (no consumer should ever treat this gate
-- as a hard-decline source) -- 'live_soft_flag' is the real live signal, and
-- 'shadow_would_decline' is the recorded-but-inactive full-strength result
-- for Peter to review once 25-30 real candidates have been scored. Flipping
-- this gate to an actual decline is Peter's call, not a build decision.
DECLARE
  v_raw_composite numeric;
  v_raw_floor CONSTANT numeric := 40;
  v_raw_low boolean := false;
  v_sjt_score numeric;
  v_sjt_floor CONSTANT numeric := 50;
  v_sjt_n int;
  v_sjt_low boolean := false;
  v_reliability_clean boolean := false;
  v_im_not_flagged boolean := false;
  v_all_four boolean := false;
  v_conditions jsonb;
BEGIN
  IF p_candidate.sincerity IS NOT NULL AND p_candidate.fairness IS NOT NULL
     AND p_candidate.greed_avoidance IS NOT NULL THEN
    v_raw_composite := ROUND((p_candidate.sincerity + p_candidate.fairness + p_candidate.greed_avoidance) / 3.0, 1);
    v_raw_low := v_raw_composite < v_raw_floor;
  END IF;

  v_sjt_n := NULLIF(p_candidate.sjt_topic_detail->'sjt_honesty_integrity'->>'n', '')::int;
  IF v_sjt_n IS NOT NULL AND v_sjt_n > 0 THEN
    v_sjt_score := ROUND(100.0 * (p_candidate.sjt_topic_detail->'sjt_honesty_integrity'->>'correct')::numeric / v_sjt_n, 1);
    v_sjt_low := v_sjt_score < v_sjt_floor;
  END IF;

  v_reliability_clean := p_candidate.reliability = 'high'
    AND COALESCE(NULLIF(p_candidate.reliability_detail->>'fired_count','')::int, 0) = 0;

  v_im_not_flagged := p_candidate.impression_management_band = 'typical';

  v_all_four := v_raw_low AND v_sjt_low AND v_reliability_clean AND v_im_not_flagged;

  v_conditions := jsonb_build_object(
    'raw_composite_low', jsonb_build_object('met', v_raw_low, 'value', v_raw_composite, 'floor', v_raw_floor),
    'sjt_honesty_low',   jsonb_build_object('met', v_sjt_low, 'value', v_sjt_score, 'floor', v_sjt_floor, 'n', v_sjt_n),
    'reliability_clean', jsonb_build_object('met', v_reliability_clean, 'reliability', p_candidate.reliability,
                                             'fired_count', NULLIF(p_candidate.reliability_detail->>'fired_count','')::int),
    'faking_not_flagged', jsonb_build_object('met', v_im_not_flagged, 'band', p_candidate.impression_management_band)
  );

  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', false,
    'shadow_would_decline', v_all_four,
    'live_soft_flag', v_all_four,
    'conditions', v_conditions,
    'mode', 'shadow'
  );
END;
$function$
CREATE OR REPLACE FUNCTION public.hiregauge_lss_penalty_v2(p_composite numeric, p_floor numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
/*
2c comp-side monotonic floor-only curve for LSS penalty multiplier.

  penalty_multiplier =
    1.0                                              if p_composite IS NULL
    1.0                                              if p_floor     IS NULL
    1.0                                              if p_composite >= p_floor
    exp(-3.0 * (p_floor - p_composite) / p_floor)    otherwise

Range: [0, 1]. Multiplier applied to the role-fit base score.

SLOPE CONSTANT: k = 3.0
Research grounding for slope selection:
- Research-defensible slope range is k ≈ 2.0 to 4.0, tighter convergence at k ≈ 2.5-3.5:
  * Sweller 1988 (cognitive load theory) — task demands exceeding working memory by ~30%
    yield severe degradation. Back-solving from "20% below floor ≈ 0.5 multiplier" gives k ≈ 3.47.
  * Zhou, Kuncel & Sackett 2024 (J Intelligence 12(4), 37) — Necessary Condition Analysis
    ceiling curves for cognitive ability × job performance map to k ≈ 2.5-3.5.
  * 2-parameter IRT literature — high-stakes cognitive tests use discrimination a ≈ 1.7,
    translating to effective near-inflection k ≈ 2.5-3.5.
  * Ravens Progressive Matrices lineage — below-threshold complex-reasoning performance
    drops steeper than linear; empirical slopes cluster k ≈ 2.5-3.5.
- k=3.0 is the empirically-defensible middle of the research-supported range.
- No research finding uniquely pins k. No finding supports k<2 or k>4.

CURVE SHAPE grounding:
- Coward & Sackett 1990 (JAP 75(3), 297-300) — mainstream ability-performance curve is
  LINEAR across most of the range. Exponential-below-floor is a scoring design choice
  for the near-floor decision window, not an empirical curve fit.
- Kane 1996 (Applied Measurement in Education 9(4), 355-379) — measurement precision
  matters most near the cut score. Motivates steep gradient at the floor.
- Sweller 1988 — cognitive load theory mechanism for sharp near-floor degradation.
- Zhou/Kuncel/Sackett 2024 — "virtually necessary condition" pattern at low ability.

Recalibration rule:
- Slope k should be tuned empirically only when ≥15 real hires have on-job outcome data.
- Do not tune based on candidate scores from the pre-outcome cohort.
*/
DECLARE
  k CONSTANT numeric := 3.0;
BEGIN
  IF p_composite IS NULL OR p_floor IS NULL THEN
    RETURN 1.0;
  ELSIF p_composite >= p_floor THEN
    RETURN 1.0;
  ELSE
    RETURN exp(-k * (p_floor - p_composite) / p_floor);
  END IF;
END;
$function$
CREATE OR REPLACE FUNCTION public.hiregauge_lss_ceiling_penalty_v2(p_composite numeric, p_ceiling numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
/*
2d fit-side above-ceiling quadratic curve for LSS penalty multiplier.

  penalty_multiplier =
    1.0                                                              if p_composite IS NULL
    1.0                                                              if p_ceiling   IS NULL
    1.0                                                              if p_composite <= p_ceiling
    1.0                                                              if p_ceiling  >= 100
    GREATEST(0, 1.0 - 0.4 * ((p_composite - p_ceiling) / (100 - p_ceiling))^2)   otherwise

Range: [0.6, 1.0] under normal calibration (composite capped at 100 per
hiregauge_lss_delta_v2). Multiplier applied to role_fit base score alongside
the below-floor multiplier from hiregauge_lss_penalty_v2 — the two half-curves
compose to form the 2d asymmetric fit surface.

QUADRATIC COEFFICIENT: 0.4
Research grounding for coefficient selection:
- Wilk & Sackett 1996 (Personnel Psychology 49, 937-967) — ability-complexity
  misfit drives voluntary movement; underfit effect approximately 2.5x
  overfit effect magnitude. Ratio governs relative curve intensity between
  the two halves of the 2d surface.
- Floor helper max penalty (composite=0, floor=100) yields multiplier ~0.05
  (95% reduction). Ceiling helper max penalty (composite=100, ceiling below
  100) yields multiplier 0.6 (40% reduction). Ratio 0.95 / 0.40 = 2.375x,
  matching Wilk & Sackett empirical asymmetry within calibration precision.
- Coefficient 0.4 is the empirically-defensible value that produces this
  asymmetric magnitude.

CURVE SHAPE grounding (quadratic, not exponential):
- Ganzach 1998 (JAP 83, 526-539) — intelligence-satisfaction moderation by
  job complexity: high-ability workers in low-complexity roles experience
  gradually accumulating dissatisfaction, not sharp near-boundary cliff.
  Quadratic shape captures gradual accumulation better than exponential.
- Erdogan, Bauer, Peiro & Truxillo 2011 (Industrial and Organizational
  Psychology 4, 215-232) — overqualification is a construct with
  moderator-dependent outcomes (empowerment, autonomy). Effect is gradual
  and reversible, not steep and disqualifying.
- Maltarich, Nyberg & Reilly 2010 (JAP 95, 1058-1070) — cognitive ability
  x voluntary turnover overall r=-0.05 (small negative). Superstar effect
  at extreme top of demanding jobs traces to external-option pull, not
  internal-role misfit push. Justifies BOUNDED penalty (max 40% reduction),
  not open-ended.
- Brown, Wai & Chabris 2021 (Perspectives on Psychological Science 16,
  1337-1359) — acknowledged counterpoint arguing against general upper
  threshold for life outcomes. Scope distinction preserved: this ceiling
  models role-specific fit within a specific comp structure, not "too smart
  in general is bad."

MECHANISM DISTINCTION vs below-floor helper:
- Below-floor (2c/2d floor half): capability mismatch. Person cannot execute
  the cognitive demands of the role. Effect compounds. Exponential shape
  with steep near-floor gradient.
- Above-ceiling (2d ceiling half): motivation and retention mismatch. Person
  can execute but is underemployed. Effect gradual. Quadratic shape with
  bounded maximum.

Recalibration rule:
- Coefficient should be tuned empirically only when >=15 real hires have
  on-job outcome data.
- Do not tune based on candidate scores from the pre-outcome cohort.
*/
DECLARE
  c CONSTANT numeric := 0.4;
BEGIN
  IF p_composite IS NULL OR p_ceiling IS NULL THEN
    RETURN 1.0;
  ELSIF p_composite <= p_ceiling THEN
    RETURN 1.0;
  ELSIF p_ceiling >= 100 THEN
    RETURN 1.0;
  ELSE
    RETURN GREATEST(
      0.0,
      1.0 - c * POWER((p_composite - p_ceiling) / (100.0 - p_ceiling), 2)
    );
  END IF;
END;
$function$
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_0_facet_direct_2026_08_06

Facet-direct role-fit core. Direct weighted sum over 27 inputs (25
personality/goal-orientation facets, computed as percentiles against
hiregauge_facet_norms, plus gma and sjt already expressed 0-100) using
per-role weights from hiregauge_role_facet_weights.

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

GMA input: denominator is the LIVE count of scoreable GMA items this
candidate answered (hiregauge_candidate_responses joined to
hiregauge_instrument_items, section='newtworks_v2_cognitive_gma',
cognitive_domain IS NOT NULL, retest_of_item_number IS NULL) -- same filter
as apply_newtworks_gma_to_candidate, same population on both sides of the
division. Never a hardcoded item-bank size (hiregauge_v2_normalized_inputs'
docstring records a hardcoded 16 producing >100% scores once the item bank
grew past that count while three stray items were live at stint 2; the bank
now holds 75 scoreable items under adaptive serving).

SJT input: sjt_score used directly, already 0-100, no transformation.

Fit formula: fit = clamp( SUM(weight_i * effective_i) / SUM(weight_i WHERE
weight_i > 0 AND value_i IS NOT NULL), 0, 100 ). A NULL-valued input (no
percentile norm, e.g. the deliberately-parked competitiveness facet, or a
raw score the candidate never produced) is excluded from both the numerator
and the positive-weight denominator, and listed in missing_inputs. Negative-
weight inputs (e.g. anger) subtract in the numerator without inflating the
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
  v_citation text;
  v_gma_n numeric;
  v_weighted_sum numeric := 0;
  v_denom numeric := 0;
  v_detail jsonb := '{}'::jsonb;
  v_missing text[] := ARRAY[]::text[];
  v_fit numeric;
BEGIN
  IF p_candidate.achievement_striving IS NULL THEN
    RETURN jsonb_build_object('error', 'no_trait_data', 'role_category', p_role_category);
  END IF;

  v_candidate_json := to_jsonb(p_candidate);

  FOREACH v_name IN ARRAY v_input_names LOOP
    SELECT weight, citation INTO v_weight, v_citation
      FROM public.hiregauge_role_facet_weights
      WHERE agency_id = p_candidate.agency_id
        AND role_category = p_role_category
        AND input_name = v_name;
    v_weight := COALESCE(v_weight, 0);

    IF v_name = 'gma' THEN
      SELECT count(*)::numeric INTO v_gma_n
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL;
      v_value := CASE
        WHEN p_candidate.gma_total_accuracy IS NULL OR COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE ROUND(p_candidate.gma_total_accuracy::numeric / v_gma_n * 100.0)
      END;
    ELSIF v_name = 'sjt' THEN
      v_value := p_candidate.sjt_score;
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
        'value', NULL, 'effective', NULL, 'weight', v_weight, 'basis', v_citation));
      CONTINUE;
    END IF;

    v_eff := v_value;
    IF p_role_category = 'sales_outbound' AND v_name = 'assertiveness' AND v_eff > 75 THEN
      v_eff := 75 - (v_eff - 75) * 0.5;
    ELSIF p_role_category IN ('retention_reception','retention_support') AND v_name = 'cautiousness' AND v_eff > 80 THEN
      v_eff := 80 - (v_eff - 80) * 0.5;
    END IF;

    v_detail := v_detail || jsonb_build_object(v_name, jsonb_build_object(
      'value', v_value, 'effective', v_eff, 'weight', v_weight, 'basis', v_citation));

    v_weighted_sum := v_weighted_sum + v_weight * v_eff;
    IF v_weight > 0 THEN
      v_denom := v_denom + v_weight;
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
    'missing_inputs', to_jsonb(v_missing)
  );
END;
$function$
