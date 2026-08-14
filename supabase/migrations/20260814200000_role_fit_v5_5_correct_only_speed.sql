-- CORRECT-ITEMS-ONLY SPEED (Peter directive 2026-08-14, same session as v5.4).
-- Peter's framing: "faster should help when the answer is correct, but does
-- nothing when the answer is wrong." This matches established practice in
-- cognitive-ability testing: a fast WRONG answer usually signals a guess, not
-- quick thinking, so response time is only informative on items answered
-- correctly. Standard treatment excludes incorrect items from response-time
-- analysis entirely (Kyllonen & Zu 2016 J. Intelligence 4(14) -- "It has been
-- common practice in the cognitive psychology literature to exclude incorrect
-- items when computing response time"). Separately, guess-detection systems
-- treat unusually fast correct responses as more likely to be lucky guesses,
-- and fast incorrect responses are not counted as valid speed signal at all --
-- consistent with dropping wrong-item time from the metric rather than
-- penalizing it.
--
-- METRIC CHANGE: was "items answered per minute" (every item, right or wrong,
-- using the four aggregate gma_*_speed_seconds subtest columns). Now:
-- "items answered CORRECTLY per minute of time spent on those correct items"
-- -- computed live from hiregauge_candidate_responses.served_at/answered_at,
-- filtered to is_correct = true. A wrong item contributes zero to both the
-- numerator (not a correct item) and the denominator (its time is excluded) --
-- exactly "does nothing when the answer is wrong." The four aggregate
-- gma_*_speed_seconds columns are no longer used in this calculation (they
-- can't separate correct-item time from incorrect-item time); the four
-- columns themselves are left in place, just unused by this function now.
--
-- Same gating as v5.3/v5.4: NULL (falls back to accuracy-only) if overall
-- accuracy is below the 62.5% reasoning floor, or there are zero correct
-- items with valid timing. The floor still matters here -- without it, a
-- candidate who guesses rapidly and gets a few lucky hits could show an
-- inflated correct-items-per-minute rate on a tiny, noisy sample.
--
-- Pool norm recomputed on the new metric, same 31-candidate pool, same
-- percent-correct >= 62.5 gate (all 31 still clear it): mean 2.2380
-- correct-items/min, sd 1.0442. (Recomputed norm mean is lower than the old
-- items-per-minute norm, 8.39 -- expected, since this measures time-to-a-
-- correct-answer specifically rather than raw item-to-item pace.)

UPDATE public.hiregauge_facet_norms
SET ref_mean_0_100 = 2.2380,
    ref_sd_0_100 = 1.0442,
    source_scale = 'newtworks_v2 GMA section, CORRECT items answered per minute of time spent on those correct items (wrong items excluded entirely), gated on overall percent-correct >= 62.5',
    citation = 'Local applicant-pool norm (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014); correct-only response-time design: Kyllonen & Zu 2016 J. Intelligence 4(14) (standard practice excludes incorrect items from RT analysis); fused-input design basis: Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551; Vandierendonck 2017 Behav Res Methods 49:653-673; Vandierendonck 2018 J Cognition 1(1):8; Liesefeld & Janczyk 2019 Behav Res Methods',
    retrieved_from = 'computed from 31 completed v2 assessments with per-item served_at/answered_at timing, 2026-08-14',
    notes = 'REFRESH AT N>=50: recompute mean/sd over completed v2 pool. Higher correct-items-per-minute = better (natural direction, no inversion). USED INTERNALLY as of v5.4/v5.5 (2026-08-14) to fold speed into the single gma percentile at a 3:1 accuracy:speed ratio -- gma_speed is not a standalone weighted role-fit input. v5.5: metric redefined to correct-items-only timing (was all-items timing in v5.3/v5.4) per Peter directive -- wrong answers no longer contribute to speed in either direction.',
    updated_at = now(),
    updated_by = 'claude_grunt_thread'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet = 'gma_speed';

CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_5_correct_only_speed_2026_08_14

Facet-direct role-fit core. Direct weighted sum over 27 inputs -- 25
personality/goal-orientation facets as percentiles against published norms
in hiregauge_facet_norms, plus gma (a fused accuracy+speed score) and sjt as
percentiles against LOCAL APPLICANT-POOL norms in the same table -- using
per-role weights from hiregauge_role_facet_weights.

GMA FUSION (added 2026-08-14, role_fit_v5_4, metric refined v5_5): the
candidate-detail page shows a single "General Mental Ability" number, so
that number is the complete accuracy+speed formula rather than accuracy
alone with speed living as a separate input. Fusion method: percentile
accuracy against its pool norm, percentile speed against its own pool norm,
THEN combine the two percentiles -- the between-person "standardize each,
then combine" logic (Liesefeld & Janczyk 2019 Behav Res Methods, BIS
framework; matches the validated LISAS approach in Vandierendonck 2017/2018).
The rejected alternative (divide raw accuracy by raw time into one ratio,
i.e. rate-correct score) is explicitly NOT used -- Vandierendonck 2018
concludes RCS is "better avoided." Combination ratio: accuracy:speed = 3:1
-- editorial, reflecting speed as a real but WEAKER predictor than accuracy
(Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551), flagged for
recalibration against real hire outcomes at N>=15.

SPEED METRIC (redefined 2026-08-14, role_fit_v5_5): Peter directive --
"faster should help when the answer is correct, but does nothing when the
answer is wrong." Speed is computed as CORRECT items answered per minute of
time spent on those correct items specifically -- live per-item timing
(hiregauge_candidate_responses.served_at / .answered_at) filtered to
is_correct = true. An item answered incorrectly contributes to neither the
numerator nor the denominator -- it simply does not exist for this
calculation, matching Peter's framing exactly. This also matches standard
practice in the response-time literature: fast-but-wrong responses usually
indicate guessing, not ability, so incorrect-item timing is excluded rather
than counted (Kyllonen & Zu 2016 J. Intelligence 4(14)). NULL (falls back to
accuracy percentile alone) if overall accuracy is below the 62.5%
reasoning-floor gate, or there are zero correctly-answered items with valid
timing -- the floor still matters here because without it, a small number of
lucky rapid guesses could produce a noisy, inflated rate.

COMMON-SCALE RULE (added 2026-08-14, role_fit_v5_2): all inputs enter the
weighted sum on a percentile scale via the single transform
hiregauge_facet_percentile. The unit-weighting literature this engine is
built on assumes standardized predictors (Wainer 1976 Psych Bull
83:213-217; Dawes 1979 Am Psychologist 34:571-582); raw scores have no
meaning without a norm reference (Nunnally & Bernstein 1994; AERA/APA/NCME
Standards 2014); within-pool rank order is the selection frame (Schmidt &
Hunter 1998 Psych Bull 124:262-274). gma/sjt/gma_speed local norms: n=31
pool, refresh at N>=50; percent-correct over adaptive item subsets
approximates ability -- IRT over the 75-item bank is the upgrade path. Band
edges in hiregauge_role_ideal_ranges compare against these pool percentiles
(their original percentile intent). The reasoning-floor gate intentionally
stays on raw percent-correct (absolute chance+2SD check) -- do not convert
it.

VALIDITY-CONDITIONED WEIGHTING (added 2026-08-13, role_fit_v5_1): the 25
self-report facet inputs have their weight scaled by protocol validity v
(see _newtworks_protocol_validity) before entering the weighted sum. gma and
sjt weights are never scaled by v -- they are the harder-to-fake,
contextualized/behavioral measures that absorb the shifted weight via the
existing renormalization (denominator = sum of effective positive weights
over non-NULL inputs). This is evidence weighting of the self-report layer,
not individual score correction -- stored candidate values are never
altered. See _newtworks_protocol_validity for full citation list
(Mueller-Hanson, Heggestad & Thornton 2003; Komar, Brown, Komar & Robie
2008; Ellingson, Sackett & Hough 1999; Meade & Craig 2012).

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

SJT input: sjt_score pool-percentiled via hiregauge_facet_percentile('sjt');
raw kept in the input detail as raw_0_100.

Fit formula: fit = clamp( SUM(effective_weight_i * effective_value_i) /
SUM(effective_weight_i WHERE effective_weight_i > 0 AND value_i IS NOT
NULL), 0, 100 ). effective_weight_i = weight_i for gma/sjt, weight_i * v for
the 25 self-report facets. A NULL-valued input (no percentile norm, e.g. the
deliberately-parked competitiveness facet, or a raw score the candidate
never produced) is excluded from both the numerator and the positive-weight
denominator, and listed in missing_inputs. Negative-weight inputs (e.g.
anger) subtract in the numerator without inflating the denominator.
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
  v_ipm numeric;
  v_n_correct numeric;
  v_correct_seconds numeric;
  v_pct_correct numeric;
  v_acc_pct numeric;
  v_speed_pct numeric;
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
    v_ipm := NULL;
    v_acc_pct := NULL;
    v_speed_pct := NULL;

    IF v_name = 'gma' THEN
      SELECT count(*)::numeric INTO v_gma_n
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL;

      -- Accuracy component
      v_raw_0_100 := CASE
        WHEN p_candidate.gma_total_accuracy IS NULL OR COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE ROUND(p_candidate.gma_total_accuracy::numeric / v_gma_n * 100.0)
      END;
      v_acc_pct := public.hiregauge_facet_percentile(p_candidate.agency_id, 'gma', v_raw_0_100);

      -- Speed component: CORRECT items only, per-item live timing. An item
      -- answered incorrectly contributes to neither n_correct nor
      -- correct_seconds -- it does nothing to speed, exactly as directed.
      v_pct_correct := v_raw_0_100;

      SELECT count(*)::numeric, SUM(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
        INTO v_n_correct, v_correct_seconds
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL
          AND r.is_correct = true;

      v_ipm := CASE
        WHEN v_pct_correct IS NULL OR v_pct_correct < 62.5 THEN NULL
        WHEN COALESCE(v_n_correct, 0) = 0 THEN NULL
        WHEN v_correct_seconds IS NULL OR v_correct_seconds = 0 THEN NULL
        ELSE ROUND(v_n_correct / (v_correct_seconds / 60.0), 2)
      END;
      v_speed_pct := public.hiregauge_facet_percentile(p_candidate.agency_id, 'gma_speed', v_ipm);

      -- Fuse: 3:1 accuracy:speed when speed available; accuracy alone otherwise.
      v_value := CASE
        WHEN v_acc_pct IS NULL THEN NULL
        WHEN v_speed_pct IS NULL THEN v_acc_pct
        ELSE ROUND((3 * v_acc_pct + v_speed_pct) / 4.0)
      END;
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
      || CASE WHEN v_name = 'sjt'
              THEN jsonb_build_object('raw_0_100', v_raw_0_100)
              WHEN v_name = 'gma'
              THEN jsonb_build_object('raw_0_100', v_raw_0_100, 'accuracy_percentile', v_acc_pct,
                                       'speed_percentile', v_speed_pct, 'correct_items_per_minute', v_ipm)
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
