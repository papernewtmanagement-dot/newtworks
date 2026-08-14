-- Phase 3 forced-choice personality: SCORING LAYER
-- Spec of record: persistent_memory 'SPEC — Grunt 1: Forced-choice personality section (Phase 3)'
-- Items 501-600 (section newtworks_v2_personality_fc) are Peter-approved content and are NOT touched here.
--
-- This migration ships, in order:
--   1. 25 PROVISIONAL norm rows 'fc_<facet>' in hiregauge_facet_norms (mean 50, SD 18)
--   2. hiregauge_facet_norm_key — the single source-to-norm-key mapping point
--   3. compute_newtworks_v2fc_facets_as_row — THE one FC win-rate function (single-source law)
--   4. Norm-key branch at the four percentile call sites, so a v2fc candidate's stored
--      facet raws percentile against fc_ norms while every other source is byte-identical
--      to prior behavior: _newtworks_role_fit_core (model_tag bumped to role_fit_v5_7),
--      hiregauge_candidate_facet_percentiles, _assessment_character_parts,
--      assessment_commitment.
-- Downstream construct/verdict/view chain is otherwise unchanged. Existing candidates
-- (assessment_source 'v2', 'v1', or NULL) keep the old path forever.

-- ---------------------------------------------------------------------------
-- 1. PROVISIONAL fc_ norms (pin: mean=50, sd=18, PROVISIONAL until N>=20
--    completed v2fc, then recompute mirroring the local-norm pattern in
--    migration 20260814043100).
-- ---------------------------------------------------------------------------
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'fc_' || f.facet,
  50,
  18,
  'newtworks_v2fc forced-choice win rate, 0-100 (wins/appearances*100; anger and anxiety stored as 100 minus calm-pole win rate)',
  'PROVISIONAL uninformative seed pending local v2fc pool norms (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014). Forced-choice format basis: Christiansen, Burns & Montgomery 2005; Cao & Drasgow 2019; Salgado & Tauriz 2014; Salgado, Anderson & Tauriz 2015.',
  'seeded by migration fc_scoring_functions_and_provisional_norms, 2026-08-14',
  'PROVISIONAL seed (mean 50, SD 18) until N>=20 completed v2fc assessments; then recompute local-pool mean/sd mirroring the gma/sjt local-norm pattern in migration 20260814043100.',
  now(),
  'claude_migration'
FROM (VALUES
  ('achievement_striving'), ('anger'), ('anxiety'), ('assertiveness'),
  ('avoid_goal_orientation'), ('cautiousness'), ('compassion'), ('competitiveness'),
  ('cooperation'), ('customer_orientation'), ('dispositional_optimism'), ('dutifulness'),
  ('emotional_stability'), ('enterprising'), ('fairness'), ('friendliness'),
  ('greed_avoidance'), ('learning_goal_orientation'), ('political_skill_networking'),
  ('proactive_personality'), ('prove_goal_orientation'), ('self_discipline'),
  ('self_efficacy'), ('sincerity'), ('trust')
) AS f(facet)
ON CONFLICT (agency_id, facet) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Single mapping point: assessment_source -> norm key
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_facet_norm_key(p_source text, p_facet text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  -- Single mapping point between a candidate's assessment_source and the norm
  -- row their facet raws are percentiled against (added 2026-08-14, Phase 3
  -- forced-choice scoring). 'v2fc' candidates read the provisional
  -- 'fc_<facet>' rows in hiregauge_facet_norms, because forced-choice win
  -- rates and Likert facet means are different scales with different
  -- reference distributions (Cao & Drasgow 2019; Salgado & Tauriz 2014;
  -- Salgado, Anderson & Tauriz 2015) -- percentiling one against the other's
  -- norms would violate the common-scale rule documented in
  -- _newtworks_role_fit_core. Every other source ('v2', 'v1', NULL) keeps the
  -- facet name unchanged. gma, sjt and gma_speed are cognitive / pool norms
  -- shared across sources and are never prefixed, even if a careless future
  -- call site routes them through here.
  SELECT CASE
    WHEN p_source = 'v2fc' AND p_facet NOT IN ('gma', 'sjt', 'gma_speed')
      THEN 'fc_' || p_facet
    ELSE p_facet
  END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. THE one FC win-rate function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2fc_facets_as_row(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- THE single win-rate computation for the Phase 3 forced-choice personality
  -- section (single-source law: no other function may compute FC win rates;
  -- consumers call this). Return shape deliberately mirrors
  -- compute_newtworks_v2_facets_as_row so a finalize writer can consume
  -- either interchangeably.
  --
  -- RESPONSE CONTRACT (delivery wiring must conform): one row per answered
  -- pair in hiregauge_candidate_responses with response_label 'A' or 'B'
  -- (case/whitespace tolerated here; response_value is ignored by scoring).
  -- Timing lands in served_at / answered_at per the existing section-timing
  -- pattern.
  --
  -- SCORING: each answered item gives BOTH side facets one appearance; the
  -- chosen side's facet gets the win. raw = wins / appearances * 100, over
  -- the item's choices jsonb ({A:{text,facet,desirability},B:{...}}, items
  -- 501-600). Denominator counts APPEARANCES ON ANSWERED ITEMS, so a partial
  -- sitting is scored over what was actually answered rather than deflated
  -- against the full 8-appearance design.
  --
  -- CRITICAL PIN (spec of record): anger and anxiety statements are worded
  -- from the CALM pole, so for those two facets raw = 100 - win rate. Stored
  -- direction then matches Likert semantics (high anger = angry) and the
  -- negative anger role-fit weight keeps working unchanged.
  --
  -- is_active governs SERVING only; score_excluded governs SCORING only --
  -- same separation, for the same reason, as documented in
  -- compute_newtworks_v2_facets_as_row (2026-08-06 incident).
  --
  -- Percentile display and role-fit input for these raws resolve against the
  -- 'fc_<facet>' norm rows via hiregauge_facet_norm_key. Format research:
  -- Christiansen, Burns & Montgomery 2005 (verified desirability matching is
  -- the load-bearing property); Cao & Drasgow 2019; Salgado & Tauriz 2014;
  -- Salgado, Anderson & Tauriz 2015. Protocol-validity layer stays on
  -- (Martinez & Salgado 2021). Thurstonian IRT is the documented upgrade
  -- path only.
  WITH answered AS (
    SELECT i.choices, upper(btrim(r.response_label)) AS chosen
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality_fc'
      AND i.score_excluded IS NOT TRUE
      AND i.choices ? 'A' AND i.choices ? 'B'
      AND upper(btrim(r.response_label)) IN ('A', 'B')
  ),
  sides AS (
    SELECT a.choices -> 'A' ->> 'facet' AS facet, (a.chosen = 'A')::int AS win
    FROM answered a
    UNION ALL
    SELECT a.choices -> 'B' ->> 'facet' AS facet, (a.chosen = 'B')::int AS win
    FROM answered a
  )
  SELECT
    s.facet AS hypothesized_trait,
    ROUND(CASE WHEN s.facet IN ('anger', 'anxiety')
               THEN 100.0 - (AVG(s.win) * 100.0)
               ELSE AVG(s.win) * 100.0 END)::int AS facet_score,
    COUNT(*)::int AS n_items_scored
  FROM sides s
  WHERE s.facet IS NOT NULL
  GROUP BY s.facet;
$function$;

-- ---------------------------------------------------------------------------
-- 4a. _newtworks_role_fit_core — norm-key branch on the 25 self-report facet
--     lookups only; gma / sjt / gma_speed untouched. model_tag v5_6 -> v5_7.
--     Everything else byte-identical to v5_6.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
model_tag: role_fit_v5_7_fc_norm_keys_2026_08_14

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
from resume_analysis.qualifications.prior_similar_role.roles[].tenure_months
(sum across all listed roles, missing per-role tenure treated as 0). No
roles data at all -> multiplier 1.0 (no change from pre-v5.6 behavior,
never guesses). Multiplier = LEAST(1.0, 0.5 + 0.5*LEAST(months,24)/24.0) --
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
overall accuracy is below the 62.5% reasoning-floor gate, or there are zero
correctly-answered items with valid timing.

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
  v_raw_0_100 numeric;
  v_ipm numeric;
  v_n_correct numeric;
  v_correct_seconds numeric;
  v_pct_correct numeric;
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
      v_acc_pct := public.hiregauge_facet_percentile(p_candidate.agency_id, 'gma', v_raw_0_100);

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

      v_value := CASE
        WHEN v_acc_pct IS NULL THEN NULL
        WHEN v_speed_pct IS NULL THEN v_acc_pct
        ELSE ROUND((3 * v_acc_pct + v_speed_pct) / 4.0)
      END;
    ELSIF v_name = 'sjt' THEN
      v_raw_0_100 := p_candidate.sjt_score;
      v_value := public.hiregauge_facet_percentile(p_candidate.agency_id, 'sjt', v_raw_0_100);

      -- Experience-informed weight softening (does not touch v_value/score itself)
      IF jsonb_typeof(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') = 'array'
         AND jsonb_array_length(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') > 0 THEN
        SELECT COALESCE(SUM(COALESCE((role->>'tenure_months')::numeric, 0)), 0) INTO v_exp_months
          FROM jsonb_array_elements(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') AS role;
        v_exp_mult := LEAST(1.0, 0.5 + 0.5 * LEAST(v_exp_months, 24) / 24.0);
      ELSE
        v_exp_months := NULL;
        v_exp_mult := 1.0;
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

-- ---------------------------------------------------------------------------
-- 4b. hiregauge_candidate_facet_percentiles — display path, same branch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_candidate_facet_percentiles(p_candidate_id uuid)
 RETURNS TABLE(facet text, percentile integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- 2026-08-14 (Phase 3 FC scoring): norm key now resolves through
  -- hiregauge_facet_norm_key so v2fc candidates' win-rate raws percentile
  -- against the 'fc_<facet>' norm rows; all other sources unchanged.
  WITH cand AS (
    SELECT agency_id, assessment_source, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, anxiety, friendliness, anger, cooperation, trust,
      dispositional_optimism, political_skill_networking, enterprising,
      sincerity, fairness, greed_avoidance, assertiveness, compassion,
      competitiveness, learning_goal_orientation, prove_goal_orientation,
      avoid_goal_orientation
    FROM public.hiring_candidates WHERE id = p_candidate_id
  ),
  unpivoted AS (
    SELECT c.agency_id, c.assessment_source, v.facet, v.raw
    FROM cand c,
    LATERAL (VALUES
      ('achievement_striving', c.achievement_striving),
      ('self_discipline', c.self_discipline),
      ('emotional_stability', c.emotional_stability),
      ('dutifulness', c.dutifulness),
      ('customer_orientation', c.customer_orientation),
      ('self_efficacy', c.self_efficacy),
      ('proactive_personality', c.proactive_personality),
      ('cautiousness', c.cautiousness),
      ('anxiety', c.anxiety),
      ('friendliness', c.friendliness),
      ('anger', c.anger),
      ('cooperation', c.cooperation),
      ('trust', c.trust),
      ('dispositional_optimism', c.dispositional_optimism),
      ('political_skill_networking', c.political_skill_networking),
      ('enterprising', c.enterprising),
      ('sincerity', c.sincerity),
      ('fairness', c.fairness),
      ('greed_avoidance', c.greed_avoidance),
      ('assertiveness', c.assertiveness),
      ('compassion', c.compassion),
      ('competitiveness', c.competitiveness),
      ('learning_goal_orientation', c.learning_goal_orientation),
      ('prove_goal_orientation', c.prove_goal_orientation),
      ('avoid_goal_orientation', c.avoid_goal_orientation)
    ) AS v(facet, raw)
  )
  SELECT u.facet, public.hiregauge_facet_percentile(u.agency_id, public.hiregauge_facet_norm_key(u.assessment_source, u.facet), u.raw)
  FROM unpivoted u;
$function$;

-- ---------------------------------------------------------------------------
-- 4c. _assessment_character_parts — same branch on its 7 facet lookups
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
 RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: percentile-wrapped,
  -- same divisor rule as assessment_commitment (E.1).
  -- 2026-08-13 single-source refactor: each part is validity-adjusted here via
  -- _newtworks_shrink so every consumer (assessment_character, the CandidateDetail
  -- sub-rows) sees the same believed values and sub-rows average to the construct.
  -- 2026-08-14 (Phase 3 FC scoring): facet norm keys resolve through
  -- hiregauge_facet_norm_key so v2fc candidates percentile against 'fc_<facet>'
  -- norms; all other sources unchanged.
  WITH f AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'compassion'), hc.compassion)::numeric AS compassion,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'cooperation'), hc.cooperation)::numeric AS cooperation,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'trust'), hc.trust)::numeric AS trust,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'self_discipline'), hc.self_discipline)::numeric AS self_discipline,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'achievement_striving'), hc.achievement_striving)::numeric AS achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'dutifulness'), hc.dutifulness)::numeric AS dutifulness,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'self_efficacy'), hc.self_efficacy)::numeric AS self_efficacy,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    public._newtworks_shrink(
      round((COALESCE(compassion,0) + COALESCE(cooperation,0) + COALESCE(trust,0))
        / NULLIF((compassion IS NOT NULL)::int
               + (cooperation IS NOT NULL)::int + (trust IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
        / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
               + (dutifulness IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
        / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2), v)
  FROM f;
$function$;

-- ---------------------------------------------------------------------------
-- 4d. assessment_commitment — same branch on its 6 facet lookups
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: percentile inputs, E.1
  -- divisor rule (divisor counts non-null PERCENTILES).
  -- 2026-08-13 single-source refactor: returns the validity-adjusted construct via
  -- _newtworks_shrink; there is no separate raw-construct API.
  -- 2026-08-14 (Phase 3 FC scoring): facet norm keys resolve through
  -- hiregauge_facet_norm_key so v2fc candidates percentile against 'fc_<facet>'
  -- norms; all other sources unchanged.
  WITH c AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'enterprising'), hc.enterprising) AS p_enterprising,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'achievement_striving'), hc.achievement_striving) AS p_achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'competitiveness'), hc.competitiveness) AS p_competitiveness,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'prove_goal_orientation'), hc.prove_goal_orientation) AS p_prove_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'learning_goal_orientation'), hc.learning_goal_orientation) AS p_learning_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, 'avoid_goal_orientation'), hc.avoid_goal_orientation) AS p_avoid_goal_orientation,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
      AND hc.achievement_striving IS NOT NULL
  )
  SELECT
    public._newtworks_shrink(
      round(
        (COALESCE(p_enterprising,0) + COALESCE(p_achievement_striving,0)
         + COALESCE(p_competitiveness,0) + COALESCE(p_prove_goal_orientation,0)
         + COALESCE(p_learning_goal_orientation,0)
         + COALESCE(100 - p_avoid_goal_orientation, 0))::numeric
        / NULLIF(
            (p_enterprising IS NOT NULL)::int + (p_achievement_striving IS NOT NULL)::int
            + (p_competitiveness IS NOT NULL)::int + (p_prove_goal_orientation IS NOT NULL)::int
            + (p_learning_goal_orientation IS NOT NULL)::int + (p_avoid_goal_orientation IS NOT NULL)::int,
          0)
      , 2), c.v)
  FROM c;
$function$;
