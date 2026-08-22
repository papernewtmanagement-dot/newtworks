-- SPEED AS 28th ROLE-FIT INPUT (Peter approval via planning thread, 2026-08-14).
-- All design decisions pinned in persistent_memory spec 'SPEC -- Grunt 2: Speed
-- as 28th role-fit input (v5.3)'. Speed enters as its OWN standardized input,
-- not fused into accuracy (rate-correct rejected per Vandierendonck 2018 --
-- "better avoided"; BIS between-person combination logic per Liesefeld &
-- Janczyk 2019 instead). Basis for speed correlating with cognitive ability,
-- strengthening with task complexity: Sheppard & Vernon 2008 Pers Individ Diff
-- 44(3):535-551.

-- 1) Pool norm for gma_speed, items-per-minute scale.
-- Population: same 31 completed-v2 candidates as the gma/sjt norms (achievement_striving
-- present, gma_total_accuracy present, all four gma_*_speed_seconds present), gated on
-- percent-correct >= 62.5 (all 31 clear the gate -- n unchanged at 31).
-- Computed 2026-08-14: mean 8.3923 items/min, sd 4.0697 items/min.
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'gma_speed', 8.3923, 4.0697,
   'newtworks_v2 GMA section, items answered per minute across all four subtests, gated on percent-correct >= 62.5',
   'Local applicant-pool norm (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014); speed-as-separate-input design basis: Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551; Vandierendonck 2017 Behav Res Methods 49:653-673; Vandierendonck 2018 J Cognition 1(1):8; Liesefeld & Janczyk 2019 Behav Res Methods',
   'computed from 31 completed v2 assessments with full GMA timing, 2026-08-14',
   'REFRESH AT N>=50: recompute mean/sd over completed v2 pool with full timing. Higher items-per-minute = better (natural direction, no inversion).',
   now(), 'claude_grunt_thread')
ON CONFLICT (agency_id, facet) DO UPDATE
SET ref_mean_0_100 = EXCLUDED.ref_mean_0_100,
    ref_sd_0_100   = EXCLUDED.ref_sd_0_100,
    source_scale   = EXCLUDED.source_scale,
    citation       = EXCLUDED.citation,
    retrieved_from = EXCLUDED.retrieved_from,
    notes          = EXCLUDED.notes,
    updated_at     = now(),
    updated_by     = 'claude_grunt_thread';

-- 2) Per-role weight rows: gma_speed weight = round(that role's gma weight / 3),
-- same -1..3 smallint scale as every existing row. NOT validity-scaled (see core
-- function docstring). aspirant 3->1, retention_escalation 2->1, retention_reception
-- 1->0, retention_support 1->0, sales_in_book 2->1, sales_inbound 2->1, sales_outbound 2->1.
INSERT INTO public.hiregauge_role_facet_weights
  (agency_id, role_category, input_name, weight, basis_type, citation, notes, updated_at, updated_by)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'aspirant', 'gma_speed', 1, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [3] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'retention_escalation', 'gma_speed', 1, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [2] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'retention_reception', 'gma_speed', 0, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [1] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'retention_support', 'gma_speed', 0, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [1] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'sales_in_book', 'gma_speed', 1, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [2] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'sales_inbound', 'gma_speed', 1, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [2] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread'),
  ('126794dd-25ff-47d2-a436-724499733365', 'sales_outbound', 'gma_speed', 1, 'study',
   'Sheppard & Vernon 2008 Pers Individ Diff 44(3):535-551', 'Editorial weight = round(gma weight [2] / 3). Not independently validity-scaled -- corroborating input alongside gma accuracy.', now(), 'claude_grunt_thread')
ON CONFLICT (agency_id, role_category, input_name) DO UPDATE
SET weight = EXCLUDED.weight,
    basis_type = EXCLUDED.basis_type,
    citation = EXCLUDED.citation,
    notes = EXCLUDED.notes,
    updated_at = now(),
    updated_by = 'claude_grunt_thread';

-- 3) Core function: add gma_speed as 28th input.
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_3_speed_input_2026_08_14

Facet-direct role-fit core. Direct weighted sum over 28 inputs -- 25
personality/goal-orientation facets as percentiles against published norms
in hiregauge_facet_norms, gma and sjt as percentiles against LOCAL
APPLICANT-POOL norms in the same table, plus gma_speed as a 28th standalone
input -- using per-role weights from hiregauge_role_facet_weights.

SPEED AS SEPARATE INPUT (added 2026-08-14, role_fit_v5_3): processing speed
enters as its OWN standardized input rather than folded into a fused
accuracy+speed score. Mental speed correlates with intelligence and that
correlation strengthens with task complexity (Sheppard & Vernon 2008 Pers
Individ Diff 44(3):535-551) -- it carries independent signal, not noise to
merge away. Rate-correct-score fusion (accuracy/time) is contraindicated
by the balanced-integration-score literature (Vandierendonck 2017 Behav
Res Methods 49:653-673; Vandierendonck 2018 J Cognition 1(1):8 -- RCS
"better avoided", inverse-efficiency only defensible for low-error data,
which this applicant pool is not guaranteed to be). Binding-of-independent-
scores logic instead: standardize each component separately, then combine
linearly at the between-person level (Liesefeld & Janczyk 2019 Behav Res
Methods, BIS framework) -- exactly what happens by giving gma_speed its own
weight column and letting the existing weighted-sum machinery combine it
with every other percentile-scaled input.

gma_speed metric: items answered (live GMA item count, same query as the
gma branch) divided by total time spent across all four GMA subtests in
minutes (sum of gma_pattern/numerical/deductive/verbal_speed_seconds / 60)
= items per minute. NULL (excluded from the weighted sum via the existing
missing-input handling) if: any of the four speed-seconds columns is NULL,
OR total time is zero, OR gma percent-correct falls below 62.5 -- the same
reasoning-floor anchor used elsewhere (chance + 2SD on a 4-way multiple
choice format), which exists here specifically to remove speed credit for
anyone racing through without engaging the reasoning (kills the rush
exploit). Percentiled via hiregauge_facet_percentile('gma_speed') against a
pool norm in items-per-minute (higher = better, natural direction, no
inversion needed unlike raw response-time scales). Raw value kept in the
input detail as items_per_minute.

gma_speed weight: not validity-scaled like gma/sjt's validity-derived
weights -- set editorially at (that role's gma weight) / 3, rounded to the
nearest whole number on the same -1..3 integer scale as every other weight
row, reflecting speed's smaller, corroborating (not primary) role relative
to accuracy within the same construct family. Grouped with the gma/sjt
branch of effective-weight logic (never scaled by protocol validity v --
same rationale as gma/sjt: harder to fake, behaviorally measured, not
self-report).

COMMON-SCALE RULE (added 2026-08-14, role_fit_v5_2): all inputs enter
the weighted sum on a percentile scale via the single transform
hiregauge_facet_percentile. The unit-weighting literature this engine is
built on assumes standardized predictors (Wainer 1976 Psych Bull
83:213-217; Dawes 1979 Am Psychologist 34:571-582); raw scores have no
meaning without a norm reference (Nunnally & Bernstein 1994; AERA/APA/NCME
Standards 2014); within-pool rank order is the selection frame (Schmidt &
Hunter 1998 Psych Bull 124:262-274). gma/sjt/gma_speed local norms: n=31
pool, refresh at N>=50; percent-correct over adaptive item subsets
approximates ability -- IRT over the 75-item bank is the upgrade path.
Band edges in hiregauge_role_ideal_ranges compare against these pool
percentiles (their original percentile intent). The reasoning-floor gate
intentionally stays on raw percent-correct (absolute chance+2SD check) --
do not convert it.

VALIDITY-CONDITIONED WEIGHTING (added 2026-08-13, role_fit_v5_1): the 25
self-report facet inputs have their weight scaled by protocol validity v
(see _newtworks_protocol_validity) before entering the weighted sum. gma,
sjt, and gma_speed weights are never scaled by v -- they are the harder-
to-fake, contextualized/behavioral measures that absorb the shifted weight
via the existing renormalization (denominator = sum of effective positive
weights over non-NULL inputs). This is evidence weighting of the
self-report layer, not individual score correction -- stored candidate
values are never altered. See _newtworks_protocol_validity for full
citation list (Mueller-Hanson, Heggestad & Thornton 2003; Komar, Brown,
Komar & Robie 2008; Ellingson, Sackett & Hough 1999; Meade & Craig 2012).

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
NULL), 0, 100 ). effective_weight_i = weight_i for gma/sjt/gma_speed,
weight_i * v for the 25 self-report facets. A NULL-valued input (no
percentile norm, e.g. the deliberately-parked competitiveness facet, a raw
score the candidate never produced, or gma_speed gated out by missing
timing or sub-floor accuracy) is excluded from both the numerator and the
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
    'prove_goal_orientation','avoid_goal_orientation','gma','sjt','gma_speed'
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
  v_total_seconds numeric;
  v_pct_correct numeric;
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

    IF v_name IN ('gma','sjt','gma_speed') THEN
      v_eff_weight := v_weight;
    ELSE
      v_eff_weight := v_weight * v_v;
    END IF;

    v_raw_0_100 := NULL;
    v_ipm := NULL;

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
    ELSIF v_name = 'gma_speed' THEN
      SELECT count(*)::numeric INTO v_gma_n
        FROM public.hiregauge_candidate_responses r
        JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
        WHERE r.candidate_id = p_candidate.id
          AND i.section = 'newtworks_v2_cognitive_gma'
          AND i.cognitive_domain IS NOT NULL
          AND i.retest_of_item_number IS NULL;
      v_pct_correct := CASE
        WHEN p_candidate.gma_total_accuracy IS NULL OR COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE p_candidate.gma_total_accuracy::numeric / v_gma_n * 100.0
      END;
      v_total_seconds := NULL;
      IF p_candidate.gma_pattern_speed_seconds IS NOT NULL
         AND p_candidate.gma_numerical_speed_seconds IS NOT NULL
         AND p_candidate.gma_deductive_speed_seconds IS NOT NULL
         AND p_candidate.gma_verbal_speed_seconds IS NOT NULL THEN
        v_total_seconds := p_candidate.gma_pattern_speed_seconds
                          + p_candidate.gma_numerical_speed_seconds
                          + p_candidate.gma_deductive_speed_seconds
                          + p_candidate.gma_verbal_speed_seconds;
      END IF;
      v_ipm := CASE
        WHEN v_pct_correct IS NULL OR v_pct_correct < 62.5 THEN NULL
        WHEN v_total_seconds IS NULL OR v_total_seconds = 0 THEN NULL
        WHEN COALESCE(v_gma_n, 0) = 0 THEN NULL
        ELSE ROUND(v_gma_n / (v_total_seconds / 60.0), 2)
      END;
      v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, 'gma_speed', v_ipm);
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
              WHEN v_name = 'gma_speed'
              THEN jsonb_build_object('items_per_minute', v_ipm)
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

