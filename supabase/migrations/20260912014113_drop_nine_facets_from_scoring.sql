-- 16-trait scoring for EVERYONE: the nine dropped facets leave every scoring path (2026-09-11).
--
-- Peter, 2026-09-11: "Stop scoring those facets that were now dropped. Stop scoring them on
-- older candidates, remove them entirely, and take them out of the functionality for the
-- scoring." This supersedes the same-day zero-flip regression bar for the 27 old-set
-- candidates: one scoring model now applies to old and new candidates alike.
--
-- The nine: sincerity, fairness, greed_avoidance, anxiety, anger, trust, competitiveness,
-- prove_goal_orientation, avoid_goal_orientation. Honesty stays measured in stint 1
-- (hiregauge_v2_stint1_exit_gate gate B, hard exit below 30); nothing here touches that.
--
-- WHAT CHANGES
--   Functions (bodies below): _assessment_character_parts (Concern = compassion + cooperation),
--   assessment_commitment (enterprising + achievement_striving + learning_goal_orientation),
--   hiregauge_candidate_facet_percentiles (16 rows), hiregauge_v2_normalized_inputs,
--   hiregauge_candidate_pool_position, newtworks_motivation_types (dropped keys read NULL),
--   _newtworks_integrity_decline_gate (retired: its only inputs were the ranking-block honesty
--   facets; it never hard-declined), compute_newtworks_v2fcq_facets_as_row (never scores the
--   nine, on any block set), _newtworks_role_fit_core (18 inputs, patched in place),
--   interview_candidate_triggers (T_AVOID_GOAL_HIGH removed, patched in place).
--   Rows: 63 hiregauge_role_facet_weights rows and 27 hiregauge_facet_norms rows (plain, fcq_,
--   fcq_@quad75) for the nine are deleted. The raw columns on hiring_candidates stay as
--   inert history; nothing reads them.
--   Bands: re-anchored with the 2026-09-04/09-10 rule (Cascio, Alexander & Barrett 1988;
--   decline ~ -1.3 SD, pass ~ +1.2 SD). Dry run on the 27 finished old-set candidates:
--   composite mean 51.08 / SD 5.61 -> 53.36 / 6.49 (max shift 6.23), so 44/58 -> 45/61.
--   Under the old bands 5 verdicts would flip; under 45/61 exactly two (57.74 -> 61.16
--   consider -> pass; 47.76 -> 44.89 consider -> decline). Verdict mix 3/22/2 -> 4/20/3
--   (pass/consider/decline). Measured with the scoring cache refreshed; a first dry run that
--   skipped the refresh read stale cached capability values and understated the change.
--
-- Self-check at the end: no NULL composites, exactly the expected flip count, weight and norm
-- rows gone, 16 percentile rows and 18 role-fit inputs per candidate. Any failure rolls back.

CREATE TEMP TABLE d9_before AS
SELECT c.id, v.composite, v.verdict
FROM public.hiring_candidates c
CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
WHERE c.assessment_source = 'v2fcq' AND c.assessment_completed_at IS NOT NULL;

-- ===== SHARED BLOCK: function rewrites that take the nine dropped facets out of scoring =====
-- Dropped 2026-09-10/11 (Peter): sincerity, fairness, greed_avoidance, anxiety, anger, trust,
-- competitiveness, prove_goal_orientation, avoid_goal_orientation. Honesty stays measured by the
-- stint-1 items (hiregauge_v2_stint1_exit_gate, gate B); nothing below touches that.

-- 1. Character: Concern for Others = compassion + cooperation (trust removed).
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
  -- 2026-09-11 (ranking-block sets): the norm key takes the candidate's fcq_block_set;
  -- a retired set reads its frozen fcq_<facet>@<set> rows.
  -- 2026-09-11 (16-trait set, Peter): trust is no longer measured or scored for anyone.
  -- Concern for Others = compassion + cooperation.
  WITH f AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'compassion'), hc.compassion)::numeric AS compassion,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'cooperation'), hc.cooperation)::numeric AS cooperation,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'self_discipline'), hc.self_discipline)::numeric AS self_discipline,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'achievement_striving'), hc.achievement_striving)::numeric AS achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'dutifulness'), hc.dutifulness)::numeric AS dutifulness,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'self_efficacy'), hc.self_efficacy)::numeric AS self_efficacy,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    public._newtworks_shrink(
      round((COALESCE(compassion,0) + COALESCE(cooperation,0))
        / NULLIF((compassion IS NOT NULL)::int + (cooperation IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
        / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
               + (dutifulness IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
        / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2), v)
  FROM f;
$function$;

-- 2. Commitment = enterprising + achievement_striving + learning_goal_orientation
--    (competitiveness, prove_goal_orientation, avoid_goal_orientation removed).
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
  -- 2026-09-11 (ranking-block sets): the norm key takes the candidate's fcq_block_set;
  -- a retired set reads its frozen fcq_<facet>@<set> rows.
  -- 2026-09-11 (16-trait set, Peter): competitiveness, prove_goal_orientation and
  -- avoid_goal_orientation are no longer measured or scored for anyone. Three inputs remain.
  WITH c AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'enterprising'), hc.enterprising) AS p_enterprising,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'achievement_striving'), hc.achievement_striving) AS p_achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, 'learning_goal_orientation'), hc.learning_goal_orientation) AS p_learning_goal_orientation,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
      AND hc.achievement_striving IS NOT NULL
  )
  SELECT
    public._newtworks_shrink(
      round(
        (COALESCE(p_enterprising,0) + COALESCE(p_achievement_striving,0) + COALESCE(p_learning_goal_orientation,0))::numeric
        / NULLIF(
            (p_enterprising IS NOT NULL)::int + (p_achievement_striving IS NOT NULL)::int
            + (p_learning_goal_orientation IS NOT NULL)::int,
          0)
      , 2), c.v)
  FROM c;
$function$;

-- 3. Facet percentile list: the 16 measured facets only.
CREATE OR REPLACE FUNCTION public.hiregauge_candidate_facet_percentiles(p_candidate_id uuid)
 RETURNS TABLE(facet text, percentile integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- 2026-08-14 (Phase 3 FC scoring): norm key resolves through hiregauge_facet_norm_key.
  -- 2026-09-11 (ranking-block sets): the norm key takes the candidate's fcq_block_set.
  -- 2026-09-11 (16-trait set, Peter): only the 16 measured facets are listed; the nine
  -- dropped facets are gone from every scoring and display path.
  WITH cand AS (
    SELECT agency_id, assessment_source, fcq_block_set, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, friendliness, cooperation, dispositional_optimism, political_skill_networking,
      enterprising, assertiveness, compassion, learning_goal_orientation
    FROM public.hiring_candidates WHERE id = p_candidate_id
  ),
  unpivoted AS (
    SELECT c.agency_id, c.assessment_source, c.fcq_block_set, v.facet, v.raw
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
      ('friendliness', c.friendliness),
      ('cooperation', c.cooperation),
      ('dispositional_optimism', c.dispositional_optimism),
      ('political_skill_networking', c.political_skill_networking),
      ('enterprising', c.enterprising),
      ('assertiveness', c.assertiveness),
      ('compassion', c.compassion),
      ('learning_goal_orientation', c.learning_goal_orientation)
    ) AS v(facet, raw)
  )
  SELECT u.facet, public.hiregauge_facet_percentile(u.agency_id, public.hiregauge_facet_norm_key(u.assessment_source, u.fcq_block_set, u.facet), u.raw)
  FROM unpivoted u;
$function$;

-- 4. Normalized inputs (feeds _newtworks_reasoning_gate): 16 facets + gma_total + sjt topics.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_normalized_inputs(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_result jsonb;
  v_gma_pct numeric;
  v_gma_n numeric;
  v_topic jsonb;
  v_topic_key text;
  v_topic_n numeric;
BEGIN
  -- 2026-09-11 (16-trait set, Peter): the nine dropped facets are no longer listed.
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  -- Reasoning percentage. The denominator is the count of reasoning items
  -- this candidate actually answered, NOT a hardcoded item-bank size (see the
  -- 2026-08 history in the migration ledger). Filter is identical to the one in
  -- apply_newtworks_gma_to_candidate -- same population on both sides of the
  -- division, retest items excluded from both.
  SELECT count(*)::numeric
    INTO v_gma_n
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;

  v_gma_pct := CASE
                 WHEN v_row.gma_total_accuracy IS NULL THEN NULL
                 WHEN COALESCE(v_gma_n, 0) = 0 THEN NULL
                 ELSE ROUND(v_row.gma_total_accuracy::numeric / v_gma_n * 100.0, 1)
               END;

  v_result := jsonb_build_object(
    'achievement_striving',        v_row.achievement_striving,
    'assertiveness',               v_row.assertiveness,
    'cautiousness',                v_row.cautiousness,
    'compassion',                  v_row.compassion,
    'cooperation',                 v_row.cooperation,
    'customer_orientation',        v_row.customer_orientation,
    'dispositional_optimism',      v_row.dispositional_optimism,
    'dutifulness',                 v_row.dutifulness,
    'emotional_stability',         v_row.emotional_stability,
    'enterprising',                v_row.enterprising,
    'friendliness',                v_row.friendliness,
    'learning_goal_orientation',   v_row.learning_goal_orientation,
    'political_skill_networking',  v_row.political_skill_networking,
    'proactive_personality',       v_row.proactive_personality,
    'self_discipline',             v_row.self_discipline,
    'self_efficacy',               v_row.self_efficacy,
    'gma_total',                   v_gma_pct
  );

  IF v_row.sjt_topic_detail IS NOT NULL THEN
    FOR v_topic_key IN SELECT jsonb_object_keys(v_row.sjt_topic_detail) LOOP
      v_topic := v_row.sjt_topic_detail -> v_topic_key;
      v_topic_n := NULLIF((v_topic ->> 'n')::numeric, 0);
      v_result := v_result || jsonb_build_object(
        v_topic_key,
        CASE WHEN v_topic_n IS NULL THEN NULL
             ELSE ROUND((v_topic ->> 'correct')::numeric / v_topic_n * 100.0, 1) END
      );
    END LOOP;
  END IF;

  RETURN v_result;
END;
$function$;

-- 5. Pool position: 16 facets.
CREATE OR REPLACE FUNCTION public.hiregauge_candidate_pool_position(p_candidate_id uuid)
 RETURNS TABLE(facet text, pool_n integer, pool_position integer, pool_percentile integer, pool_is_primary boolean)
 LANGUAGE sql
 STABLE
AS $function$
  -- Batch 0 / 0D. Read-time only -- nothing here is stored.
  -- Pool = other candidates in the same agency whose assessment_completed_at
  -- is AFTER the neutralization cutover marker in settings
  -- ('hiregauge_neutralization_cutover_at'). While that marker is NULL this
  -- returns zero rows (pool_n never reaches 2).
  -- pool_position = standard competition ranking (1 = highest raw facet value).
  -- pool_percentile only when pool_n >= 30; pool_is_primary once pool_n >= 100.
  -- 2026-09-11 (16-trait set, Peter): the nine dropped facets are gone.
  WITH target AS (
    SELECT hc.agency_id
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  ),
  cutover AS (
    SELECT NULLIF(s.setting_value, '')::timestamptz AS cutover_at
    FROM public.settings s, target t
    WHERE s.agency_id = t.agency_id
      AND s.setting_key = 'hiregauge_neutralization_cutover_at'
  ),
  cand AS (
    SELECT id, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, friendliness, cooperation, dispositional_optimism,
      political_skill_networking, enterprising, assertiveness, compassion,
      learning_goal_orientation
    FROM public.hiring_candidates, target t
    WHERE hiring_candidates.agency_id = t.agency_id
      AND hiring_candidates.assessment_completed_at IS NOT NULL
      AND (SELECT cutover_at FROM cutover) IS NOT NULL
      AND hiring_candidates.assessment_completed_at > (SELECT cutover_at FROM cutover)
  ),
  target_vals AS (
    SELECT id, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, friendliness, cooperation, dispositional_optimism,
      political_skill_networking, enterprising, assertiveness, compassion,
      learning_goal_orientation
    FROM public.hiring_candidates
    WHERE id = p_candidate_id
  ),
  target_unpivoted AS (
    SELECT v.facet, v.raw AS target_raw
    FROM target_vals tv,
    LATERAL (VALUES
      ('achievement_striving', tv.achievement_striving),
      ('self_discipline', tv.self_discipline),
      ('emotional_stability', tv.emotional_stability),
      ('dutifulness', tv.dutifulness),
      ('customer_orientation', tv.customer_orientation),
      ('self_efficacy', tv.self_efficacy),
      ('proactive_personality', tv.proactive_personality),
      ('cautiousness', tv.cautiousness),
      ('friendliness', tv.friendliness),
      ('cooperation', tv.cooperation),
      ('dispositional_optimism', tv.dispositional_optimism),
      ('political_skill_networking', tv.political_skill_networking),
      ('enterprising', tv.enterprising),
      ('assertiveness', tv.assertiveness),
      ('compassion', tv.compassion),
      ('learning_goal_orientation', tv.learning_goal_orientation)
    ) AS v(facet, raw)
  ),
  pool_unpivoted AS (
    SELECT c.id, v.facet, v.raw AS pool_raw
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
      ('friendliness', c.friendliness),
      ('cooperation', c.cooperation),
      ('dispositional_optimism', c.dispositional_optimism),
      ('political_skill_networking', c.political_skill_networking),
      ('enterprising', c.enterprising),
      ('assertiveness', c.assertiveness),
      ('compassion', c.compassion),
      ('learning_goal_orientation', c.learning_goal_orientation)
    ) AS v(facet, raw)
    WHERE c.id <> p_candidate_id
  ),
  agg AS (
    SELECT
      pu.facet,
      count(pu.pool_raw) FILTER (WHERE pu.pool_raw IS NOT NULL) AS pool_n,
      1 + count(pu.pool_raw) FILTER (
        WHERE pu.pool_raw IS NOT NULL
          AND pu.pool_raw > (SELECT tu.target_raw FROM target_unpivoted tu WHERE tu.facet = pu.facet)
      ) AS pool_position
    FROM pool_unpivoted pu
    GROUP BY pu.facet
  )
  SELECT
    a.facet,
    a.pool_n::int,
    a.pool_position::int,
    CASE WHEN a.pool_n >= 30 AND a.pool_n > 1
      THEN round(100.0 * (a.pool_n - a.pool_position) / (a.pool_n - 1))::int
      ELSE NULL END AS pool_percentile,
    (a.pool_n >= 100) AS pool_is_primary
  FROM agg a
  WHERE a.pool_n >= 2;
$function$;

-- 6. Motivation types: keeps its shape for any caller; the three dropped inputs read NULL.
CREATE OR REPLACE FUNCTION public.newtworks_motivation_types(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  -- 2026-09-11 (16-trait set, Peter): competitiveness, prove_goal_orientation and
  -- avoid_goal_orientation are no longer measured; those keys are NULL for everyone.
  SELECT jsonb_build_object(
    'achievement', hc.achievement_striving,
    'competitive', NULL,
    'recognition', NULL,
    'learning',    hc.learning_goal_orientation,
    'avoid',       NULL,
    'income',      NULL,
    'duty',        NULL
  )
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$function$;

-- 7. Verdict-time integrity gate: retired. Its only input was the three ranking-block honesty
--    facets, which are no longer measured. Honesty is measured once, in stint 1 (gate B of
--    hiregauge_v2_stint1_exit_gate, hard exit below 30). Shape kept for _newtworks_role_fit_gated_core.
CREATE OR REPLACE FUNCTION public._newtworks_integrity_decline_gate(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
-- RETIRED 2026-09-11 (16-trait set, Peter). Ran in shadow mode from 2026-08-03; never
-- hard-declined. Inputs (sincerity, fairness, greed_avoidance from the ranking blocks)
-- are no longer measured. Honesty lives in stint 1 only. Returns an inert result so
-- callers need no change.
BEGIN
  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', false,
    'shadow_would_decline', false,
    'live_soft_flag', false,
    'conditions', '{}'::jsonb,
    'mode', 'retired'
  );
END;
$function$;

-- 8. Ranking-block scorer: the nine dropped facets are never scored, on any block set.
--    The anger/anxiety calm-pole pin goes with them.
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2fcq_facets_as_row(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- THE single scoring computation for the Phase 4 forced-choice personality
  -- section (single-source law: no other function may score the quad blocks;
  -- consumers call this). Return shape mirrors compute_newtworks_v2_facets_as_row
  -- so finalize can consume either interchangeably.
  --
  -- RESPONSE CONTRACT: one row per answered block in hiregauge_candidate_responses;
  -- response_label is the block's STORED option letters in rank order, most-like-me
  -- first (e.g. "BDAC"), already translated back from display order by the edge
  -- function. Case and whitespace tolerated; response_value ignored. A label that is
  -- not a clean permutation of the block's letters is ignored, never partially scored.
  --
  -- SCORING (Phase 1, partially-ipsative normative -- Brown & Maydeu-Olivares 2011
  -- EPM 71:460-502; Schulte, Holling & Burkner 2021 EPM; Hontangas et al. 2015
  -- APM 39:598-612 for RANK on tetrads): a full ranking of 4 yields 6 pairwise
  -- comparisons; a statement at rank r (1 = most like me) has wins = 4 - r out of
  -- 3. Each facet has 12 statements x 3 = 36 comparisons per complete sitting.
  -- raw = evidence / comparisons * 100 over the blocks actually answered.
  -- n_items_scored counts statement appearances (12 per facet when complete).
  --
  -- DIRECTION LIVES ON THE STATEMENT: pole '+' = keyed to the facet's socially
  -- positive end (contributes its wins), pole '-' = its negative end (contributes
  -- its losses). There is NO facet-wide 100-minus flip.
  --
  -- 2026-09-11 (16-trait set, Peter): sincerity, fairness, greed_avoidance, anxiety,
  -- anger, trust, competitiveness, prove_goal_orientation and avoid_goal_orientation
  -- are never scored, on any block set (a rescore of an old-set sitting drops them
  -- too). The anger/anxiety calm-pole pin went with them.
  --
  -- is_active governs SERVING only; score_excluded governs SCORING only.
  -- Percentile display and role-fit input resolve against the 'fcq_<facet>' norm
  -- rows via hiregauge_facet_norm_key. Phase 2 (Thurstonian IRT at N >= 300)
  -- replaces the body of this function and nothing else.
  WITH answered AS (
    SELECT i.id AS item_id,
           i.choices -> 'options' AS options,
           upper(btrim(r.response_label)) AS ranking
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality_fc_quad'
      AND i.score_excluded IS NOT TRUE
      AND jsonb_typeof(i.choices -> 'options') = 'object'
      AND r.response_label IS NOT NULL
  ),
  valid AS (
    SELECT a.item_id, a.options, a.ranking,
           (SELECT count(*) FROM jsonb_object_keys(a.options)) AS n_letters
    FROM answered a
    WHERE length(a.ranking) = (SELECT count(*) FROM jsonb_object_keys(a.options))
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_object_keys(a.options) AS k
        WHERE length(a.ranking) - length(replace(a.ranking, k, '')) <> 1
      )
  ),
  statements AS (
    SELECT o.value ->> 'facet' AS facet,
           o.value ->> 'pole'  AS pole,
           (v.n_letters - strpos(v.ranking, o.key))::int AS wins,
           (v.n_letters - 1)::int AS comparisons
    FROM valid v
    CROSS JOIN LATERAL jsonb_each(v.options) AS o(key, value)
  ),
  oriented AS (
    SELECT s.facet,
           s.comparisons,
           CASE WHEN s.pole = '+' THEN s.wins ELSE s.comparisons - s.wins END AS evidence
    FROM statements s
    WHERE s.facet IS NOT NULL AND s.pole IN ('+', '-')
      AND s.facet NOT IN ('sincerity', 'fairness', 'greed_avoidance', 'anxiety', 'anger', 'trust',
                          'competitiveness', 'prove_goal_orientation', 'avoid_goal_orientation')
  )
  SELECT o.facet AS hypothesized_trait,
         ROUND(SUM(o.evidence)::numeric / NULLIF(SUM(o.comparisons), 0) * 100.0)::int AS facet_score,
         COUNT(*)::int AS n_items_scored
  FROM oriented o
  GROUP BY o.facet;
$function$;

-- 9. Role fit core: the 27-input list becomes 18 (16 facets + gma + sjt). Patched in place.
-- 10. Interview triggers: the T_AVOID_GOAL_HIGH rule is removed. Patched in place.
DO $$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_n int;
BEGIN
  v_def := pg_get_functiondef('public._newtworks_role_fit_core'::regproc);
  v_old := '    ''anxiety'',''friendliness'',''anger'',''cooperation'',''trust'',''dispositional_optimism'',' || E'\n'
        || '    ''political_skill_networking'',''enterprising'',''sincerity'',''fairness'',''greed_avoidance'',' || E'\n'
        || '    ''assertiveness'',''compassion'',''competitiveness'',''learning_goal_orientation'',' || E'\n'
        || '    ''prove_goal_orientation'',''avoid_goal_orientation'',''gma'',''sjt''';
  v_new := '    ''friendliness'',''cooperation'',''dispositional_optimism'',' || E'\n'
        || '    ''political_skill_networking'',''enterprising'',' || E'\n'
        || '    ''assertiveness'',''compassion'',''learning_goal_orientation'',' || E'\n'
        || '    ''gma'',''sjt''';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION '_newtworks_role_fit_core: input list not found once (found %)', v_n; END IF;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, 'AS $function$' || E'\n',
    'AS $function$' || E'\n' || '  -- 2026-09-11 (16-trait set, Peter): 18 inputs. sincerity, fairness, greed_avoidance, anxiety, anger, trust, competitiveness, prove_goal_orientation and avoid_goal_orientation are no longer measured or scored for anyone; their weight rows are deleted.' || E'\n');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.interview_candidate_triggers'::regproc);
  v_old := '    IF v_row.avoid_goal_orientation IS NOT NULL AND v_row.avoid_goal_orientation > 70 THEN' || E'\n'
        || '      v_codes := array_append(v_codes, ''T_AVOID_GOAL_HIGH'');' || E'\n'
        || '    END IF;' || E'\n';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'interview_candidate_triggers: avoid-goal rule not found once (found %)', v_n; END IF;
  v_def := replace(v_def, v_old, '    -- T_AVOID_GOAL_HIGH removed 2026-09-11: avoid_goal_orientation is no longer measured.' || E'\n');
  EXECUTE v_def;
END $$;
-- ===== END SHARED BLOCK =====

-- Rows for the nine.
DELETE FROM public.hiregauge_role_facet_weights
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND input_name IN ('sincerity','fairness','greed_avoidance','anxiety','anger','trust',
                     'competitiveness','prove_goal_orientation','avoid_goal_orientation');

DELETE FROM public.hiregauge_facet_norms n
WHERE n.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (n.facet IN ('sincerity','fairness','greed_avoidance','anxiety','anger','trust',
                   'competitiveness','prove_goal_orientation','avoid_goal_orientation')
       OR n.facet IN ('fcq_sincerity','fcq_fairness','fcq_greed_avoidance','fcq_anxiety','fcq_anger','fcq_trust',
                      'fcq_competitiveness','fcq_prove_goal_orientation','fcq_avoid_goal_orientation')
       OR n.facet IN ('fcq_sincerity@quad75','fcq_fairness@quad75','fcq_greed_avoidance@quad75','fcq_anxiety@quad75',
                      'fcq_anger@quad75','fcq_trust@quad75','fcq_competitiveness@quad75',
                      'fcq_prove_goal_orientation@quad75','fcq_avoid_goal_orientation@quad75'));

-- Verdict bands, same rule as 2026-09-04 and 2026-09-10, on the 16-trait composites.
UPDATE public.hiregauge_verdict_thresholds
SET consider_threshold = 45,
    pass_threshold = 61,
    notes = 'Assessment layer - percentile-metric composite. 61+ pass, 45-60 consider, <45 decline. RE-ANCHORED 2026-09-11 when the nine dropped facets left every scoring path (migration drop_nine_facets_from_scoring): the 27-candidate pool moved from mean 51.08 / SD 5.61 to mean 53.36 / SD 6.49. Same judgmental-normative rule as 2026-09-04 and 2026-09-10 (Cascio, Alexander & Barrett 1988): decline ~ -1.3 SD, pass ~ +1.2 SD, cutoffs clear ~2 SEM (AERA/APA/NCME Standards 2014 ch. 2, 5), permissive screen because ranking carries the utility (Taylor & Russell 1939). PROVISIONAL - advisory only, final call is a documented human decision (Schmidt, Mack & Hunter 1984). Recalibrate when the quad48 norms rebuild (N>=20 on the new blocks) and at N>=50 or against on-job outcomes, never against pre-outcome candidate scores. Construct-level weighting remains the real fix for the compression defect (open_question 54da3000).',
    updated_at = now()
WHERE layer = 'assessment';

DO $$
DECLARE
  v_weights int; v_norms int; v_null int; v_flips int; v_n int; v_pct int; v_inputs int; v_bands text;
  v_any uuid;
BEGIN
  SELECT count(*) INTO v_weights FROM public.hiregauge_role_facet_weights
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND input_name IN ('sincerity','fairness','greed_avoidance','anxiety','anger','trust',
                       'competitiveness','prove_goal_orientation','avoid_goal_orientation');
  SELECT count(*) INTO v_norms FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND (facet ~ '^(fcq_)?(sincerity|fairness|greed_avoidance|anxiety|anger|trust|competitiveness|prove_goal_orientation|avoid_goal_orientation)(@quad75)?$');
  IF v_weights <> 0 OR v_norms <> 0 THEN
    RAISE EXCEPTION 'rows for the nine still present: % weights, % norms', v_weights, v_norms;
  END IF;

  SELECT consider_threshold || '/' || pass_threshold INTO v_bands FROM public.hiregauge_verdict_thresholds WHERE layer = 'assessment';
  IF v_bands <> '45/61' THEN RAISE EXCEPTION 'bands are %, expected 45/61', v_bands; END IF;

  -- The deletes bumped hiregauge_scoring_version; refresh so the check reads live numbers.
  PERFORM public.hiregauge_refresh_scoring_cache('126794dd-25ff-47d2-a436-724499733365', 'all');

  CREATE TEMP TABLE d9_after AS
  SELECT c.id, v.composite, v.verdict
  FROM public.hiring_candidates c
  CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
  WHERE c.assessment_source = 'v2fcq' AND c.assessment_completed_at IS NOT NULL;

  SELECT count(*), count(*) FILTER (WHERE composite IS NULL) INTO v_n, v_null FROM d9_after;
  SELECT count(*) INTO v_flips FROM d9_before b JOIN d9_after a USING (id) WHERE a.verdict IS DISTINCT FROM b.verdict;
  IF v_n < 27 OR v_null <> 0 OR v_flips <> 2 THEN
    RAISE EXCEPTION 'self-check failed: % candidates, % null composites, % verdict flips (expected 2)', v_n, v_null, v_flips;
  END IF;

  SELECT id INTO v_any FROM d9_after LIMIT 1;
  SELECT count(*) INTO v_pct FROM public.hiregauge_candidate_facet_percentiles(v_any);
  SELECT count(*) INTO v_inputs
  FROM jsonb_object_keys((SELECT public._newtworks_role_fit_core(c, 'sales_outbound') -> 'inputs' FROM public.hiring_candidates c WHERE c.id = v_any));
  IF v_pct <> 16 OR v_inputs <> 18 THEN
    RAISE EXCEPTION 'shape check failed: % percentile rows (expected 16), % role-fit inputs (expected 18)', v_pct, v_inputs;
  END IF;

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'assessment_scoring_changed', 'info',
          'Assessment scoring now uses 16 traits for everyone',
          format('The nine dropped traits (sincerity, fairness, greed avoidance, anxiety, anger, trust, competitiveness, prove goal, avoid goal) no longer count for any candidate, old or new. Verdict bands re-anchored to 45/61 (were 44/58). Of %s finished candidates, %s changed verdict band.', v_n, v_flips),
          'hiring', false, false);
END $$;
