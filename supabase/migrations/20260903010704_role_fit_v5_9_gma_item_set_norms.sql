CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_9_gma_item_set_norms_2026_09_02

GMA ITEM SETS (added 2026-09-02, role_fit_v5_9): the Section 1 GMA item set
changed on 2026-09-02 (four near-ceiling items retired, four harder ones
added, count unchanged at 16). A local norm describes ONE item set, so a
candidate's gma / gma_speed percentiles are taken against the norm rows for
the set they actually answered: hiregauge_gma_candidate_set() resolves the
set (locked on hiring_candidates.gma_item_set at first GMA answer, else
inferred from the answered items), hiregauge_gma_norm_facet() maps 'gma' /
'gma_speed' to the current set's rows or to the frozen '<facet>@<set>' rows
of a retired set. Completions are never pooled across sets (Nunnally &
Bernstein 1994; AERA/APA/NCME Standards 2014, norm-referenced
interpretation requires a norm built on the same instrument). The speed
metric moved unchanged into hiregauge_gma_speed_ipm() so the role-fit
score and the norm rebuild share one formula; its reasoning-floor gate is
now read from hiregauge_gma_chance_floor() (chance + 2 SD from the actual
option counts of the candidate's set; the retired 2026-08 set keeps its
ruled 62.5% by override). Candidates on the retired set score exactly as
before this change.

Facet-direct role-fit core. Direct weighted sum over 27 inputs -- 25
personality/goal-orientation facets as percentiles against published norms
in hiregauge_facet_norms, plus gma (a fused accuracy+speed score) and sjt
as percentiles against LOCAL APPLICANT-POOL norms in the same table -- using
per-role weights from hiregauge_role_facet_weights.

FC NORM KEYS (added 2026-08-14, role_fit_v5_7): candidates with
assessment_source = 'v2fc' (Phase 3 forced-choice personality section)
carry facet raws that are forced-choice WIN RATES (items 501-600, computed
by compute_newtworks_v2fc_facets_as_row), not Likert means -- a different
scale with a different reference distribution (Cao & Drasgow 2019; Salgado
& Tauriz 2014; Salgado, Anderson & Tauriz 2015). For those candidates the
25 self-report facet lookups resolve against the provisional 'fc_<facet>'
rows in hiregauge_facet_norms (seeded mean 50 / SD 18; recompute at N>=20
completed v2fc per the local-norm pattern in 20260814043100) via the single
mapping point hiregauge_facet_norm_key. gma / sjt / gma_speed norms are
shared across sources and never prefixed. All other sources ('v2', 'v1',
NULL) are byte-identical to v5_6 behavior.

SJT EXPERIENCE SOFTENING (added 2026-08-14, role_fit_v5_6): Peter directive
-- a low SJT score can reflect limited work exposure rather than poor
judgment (SJTs measure a mix of pure judgment and acquired procedural
knowledge -- Motowidlo & Beier; McDaniel & Nguyen 2001). Does NOT alter the
SJT score itself -- softens SJT's effective_weight (how hard it can drag
the overall fit down) based on documented total work-history months, read
via public.resume_experience_months(resume_analysis), which counts each
calendar month once across the start/end dates the resume tenure extractor
writes on every role (concurrent jobs are not double-counted; older
hand-written roles with no start date add their tenure_months) and returns
NULL when no role carries usable tenure. NULL -> multiplier 1.0 (no change
from pre-v5.6 behavior, never guesses; "undated" is unknown, not zero).
Changed in role_fit_v5_8 (2026-08-18) from a plain SUM of tenure_months,
which double-counted overlapping roles and read undated roles as 0. Multiplier = LEAST(1.0, 0.5 + 0.5*LEAST(months,24)/24.0) --
0.5x weight at zero documented months, tapering linearly to full 1.0x
weight at 24 months. SJT weight is never scaled by protocol validity v
(same as gma) -- this experience multiplier is a separate, independent
dampener layered on top. Scoped to SJT only -- GMA and the 25 personality
facets are not procedural-knowledge measures and don't have this confound.
KNOWN DATA-QUALITY CAVEAT: the underlying tenure_months field comes from a
manual/in-chat resume-scoring workflow with incomplete, inconsistent
coverage (see migration comment for detail; deterministic fix scoped
separately). This function reads that same field, so it improves
automatically as that fix lands.

GMA FUSION (added 2026-08-14, role_fit_v5_4, metric refined v5_5): the
candidate-detail page shows a single "General Mental Ability" number, so
that number is the complete accuracy+speed formula rather than accuracy
alone with speed living as a separate input. Fusion method: percentile
accuracy against its pool norm, percentile speed against its own pool norm,
THEN combine the two percentiles -- the between-person "standardize each,
then combine" logic (Liesefeld & Janczyk 2019 Behav Res Methods, BIS
framework; matches the validated LISAS approach in Vandierendonck 2017/2018).
Combination ratio: accuracy:speed = 3:1 -- editorial, reflecting speed as a
real but WEAKER predictor than accuracy (Sheppard & Vernon 2008 Pers Individ
Diff 44(3):535-551), flagged for recalibration against real hire outcomes at
N>=15.

SPEED METRIC (redefined 2026-08-14, role_fit_v5_5): speed is computed as
CORRECT items answered per minute of time spent on those correct items
specifically -- live per-item timing (hiregauge_candidate_responses.
served_at / .answered_at) filtered to is_correct = true. An item answered
incorrectly contributes to neither the numerator nor the denominator, per
Peter directive ("faster should help when correct, does nothing when
wrong") and standard response-time practice (Kyllonen & Zu 2016 J.
Intelligence 4(14)). NULL (falls back to accuracy percentile alone) if
overall accuracy is below the reasoning-floor gate for the candidate's item
set (hiregauge_gma_chance_floor; 62.5% on the retired 2026-08 set), or there
are zero correctly-answered items with valid timing. Computed by
hiregauge_gma_speed_ipm since v5_9.

COMMON-SCALE RULE (added 2026-08-14, role_fit_v5_2): all inputs enter the
weighted sum on a percentile scale via the single transform
hiregauge_facet_percentile. The unit-weighting literature this engine is
built on assumes standardized predictors (Wainer 1976 Psych Bull
83:213-217; Dawes 1979 Am Psychologist 34:571-582); raw scores have no
meaning without a norm reference (Nunnally & Bernstein 1994; AERA/APA/NCME
Standards 2014); within-pool rank order is the selection frame (Schmidt &
Hunter 1998 Psych Bull 124:262-274). gma/sjt/gma_speed local norms: n=31
pool, refresh at N>=50. The reasoning-floor gate intentionally stays on raw
percent-correct (absolute chance+2SD check) -- do not convert it.

VALIDITY-CONDITIONED WEIGHTING (added 2026-08-13, role_fit_v5_1): the 25
self-report facet inputs have their weight scaled by protocol validity v
(see _newtworks_protocol_validity) before entering the weighted sum. gma and
sjt weights are never scaled by v. See _newtworks_protocol_validity for full
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

Fit formula: fit = clamp( SUM(effective_weight_i * effective_value_i) /
SUM(effective_weight_i WHERE effective_weight_i > 0 AND value_i IS NOT
NULL), 0, 100 ). A NULL-valued input is excluded from both the numerator and
the positive-weight denominator, and listed in missing_inputs. Negative-
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
  v_eff_weight numeric;
  v_citation text;
  v_gma_n numeric;
  v_gma_set text;
  v_raw_0_100 numeric;
  v_ipm numeric;
  v_acc_pct numeric;
  v_speed_pct numeric;
  v_exp_months numeric;
  v_exp_mult numeric;
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
    v_exp_months := NULL;
    v_exp_mult := NULL;

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
      -- v5_9: norms are per item set (see GMA ITEM SETS above).
      v_gma_set := public.hiregauge_gma_candidate_set(p_candidate.id);
      v_acc_pct := public.hiregauge_facet_percentile(p_candidate.agency_id,
                     public.hiregauge_gma_norm_facet('gma', v_gma_set), v_raw_0_100);

      -- Correct-items-only speed, gated on the set's reasoning floor (same
      -- formula as v5_5, now shared with the norm rebuild).
      v_ipm := public.hiregauge_gma_speed_ipm(p_candidate.id);
      v_speed_pct := public.hiregauge_facet_percentile(p_candidate.agency_id,
                       public.hiregauge_gma_norm_facet('gma_speed', v_gma_set), v_ipm);

      v_value := CASE
        WHEN v_acc_pct IS NULL THEN NULL
        WHEN v_speed_pct IS NULL THEN v_acc_pct
        ELSE ROUND((3 * v_acc_pct + v_speed_pct) / 4.0)
      END;
    ELSIF v_name = 'sjt' THEN
      v_raw_0_100 := p_candidate.sjt_score;
      v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, 'sjt', v_raw_0_100);

      -- Experience-informed weight softening (does not touch v_value/score itself).
      -- v5_8: total months come from public.resume_experience_months, which
      -- counts each calendar month once across overlapping roles (start/end
      -- dates written by the resume tenure extractor) and returns NULL when
      -- no role carries usable tenure. NULL means "unknown", never zero.
      v_exp_months := public.resume_experience_months(p_candidate.resume_analysis);
      IF v_exp_months IS NULL THEN
        v_exp_mult := 1.0;
      ELSE
        v_exp_mult := LEAST(1.0, 0.5 + 0.5 * LEAST(v_exp_months, 24) / 24.0);
      END IF;

      v_eff_weight := v_eff_weight * v_exp_mult;
    ELSE
      v_raw := (v_candidate_json->>v_name)::numeric;
      IF v_raw IS NULL THEN
        v_value := NULL;
      ELSE
        v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, public.hiregauge_facet_norm_key(p_candidate.assessment_source, v_name), v_raw);
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
              THEN jsonb_build_object('raw_0_100', v_raw_0_100, 'experience_months', v_exp_months, 'experience_multiplier', v_exp_mult)
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
