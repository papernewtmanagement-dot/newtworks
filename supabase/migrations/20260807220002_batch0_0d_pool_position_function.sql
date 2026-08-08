-- Batch 0 / 0D — applicant-pool position computation
-- Read-time only. Nothing here is stored as a column -- pool membership,
-- rank, and percentile all shift every time a candidate completes an
-- assessment, so this is computed fresh on every call, same pattern as
-- hiregauge_candidate_facet_percentiles.

CREATE OR REPLACE FUNCTION public.hiregauge_candidate_pool_position(p_candidate_id uuid)
RETURNS TABLE(
  facet text,
  pool_n integer,
  pool_position integer,
  pool_percentile integer,
  pool_is_primary boolean
)
LANGUAGE sql
STABLE
AS $function$
  -- Pool = other candidates in the same agency whose assessment_completed_at
  -- is AFTER the neutralization cutover marker in settings
  -- ('hiregauge_neutralization_cutover_at'). While that marker is NULL
  -- (pre-cutover), this returns zero rows for every facet -- pool_n never
  -- reaches 2, so nothing is emitted per the >= 2 threshold below.
  --
  -- pool_position is standard competition ranking (1 = highest raw facet
  -- value): 1 + count of OTHER pool candidates with a strictly higher raw
  -- value than this candidate's raw value for that facet. Ties share the
  -- same (lower/better) position. This candidate's own raw value is used
  -- for ranking regardless of whether their own assessment_completed_at
  -- itself qualifies for the pool -- pool_n counts only actual pool
  -- members (id <> p_candidate_id excluded from the pool set to avoid
  -- double-counting if this candidate happens to also be a pool member).
  --
  -- pool_percentile (only when pool_n >= 30): higher-is-better empirical
  -- percentile = round(100 * (pool_n - pool_position) / (pool_n - 1)).
  -- pool_is_primary = true once pool_n >= 100 (display decides what to
  -- do with that flag -- this function only reports it).
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
      cautiousness, anxiety, friendliness, anger, cooperation, trust,
      dispositional_optimism, political_skill_networking, enterprising,
      sincerity, fairness, greed_avoidance, assertiveness, compassion,
      competitiveness, learning_goal_orientation, prove_goal_orientation,
      avoid_goal_orientation
    FROM public.hiring_candidates, target t
    WHERE hiring_candidates.agency_id = t.agency_id
      AND hiring_candidates.assessment_completed_at IS NOT NULL
      AND (SELECT cutover_at FROM cutover) IS NOT NULL
      AND hiring_candidates.assessment_completed_at > (SELECT cutover_at FROM cutover)
  ),
  target_vals AS (
    SELECT id, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, anxiety, friendliness, anger, cooperation, trust,
      dispositional_optimism, political_skill_networking, enterprising,
      sincerity, fairness, greed_avoidance, assertiveness, compassion,
      competitiveness, learning_goal_orientation, prove_goal_orientation,
      avoid_goal_orientation
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
      ('anxiety', tv.anxiety),
      ('friendliness', tv.friendliness),
      ('anger', tv.anger),
      ('cooperation', tv.cooperation),
      ('trust', tv.trust),
      ('dispositional_optimism', tv.dispositional_optimism),
      ('political_skill_networking', tv.political_skill_networking),
      ('enterprising', tv.enterprising),
      ('sincerity', tv.sincerity),
      ('fairness', tv.fairness),
      ('greed_avoidance', tv.greed_avoidance),
      ('assertiveness', tv.assertiveness),
      ('compassion', tv.compassion),
      ('competitiveness', tv.competitiveness),
      ('learning_goal_orientation', tv.learning_goal_orientation),
      ('prove_goal_orientation', tv.prove_goal_orientation),
      ('avoid_goal_orientation', tv.avoid_goal_orientation)
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
