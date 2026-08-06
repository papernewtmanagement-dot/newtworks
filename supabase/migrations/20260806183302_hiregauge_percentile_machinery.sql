CREATE OR REPLACE FUNCTION public.hiregauge_normal_cdf(z numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
-- Abramowitz & Stegun 7.1.26 erf approximation, |error| < 1.5e-7
DECLARE t numeric; e numeric; az numeric;
BEGIN
  IF z IS NULL THEN RETURN NULL; END IF;
  az := abs(z)/sqrt(2.0);
  t := 1.0/(1.0 + 0.3275911*az);
  e := 1.0 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t
        - 0.284496736)*t + 0.254829592)*t * exp(-az*az);
  RETURN CASE WHEN z >= 0 THEN 0.5*(1.0+e) ELSE 0.5*(1.0-e) END;
END; $$;

CREATE OR REPLACE FUNCTION public.hiregauge_facet_percentile(
  p_agency uuid, p_facet text, p_raw numeric)
RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_raw IS NULL THEN NULL ELSE
    LEAST(99, GREATEST(1, round(100 * public.hiregauge_normal_cdf(
      (p_raw - n.ref_mean_0_100) / n.ref_sd_0_100 ))))::int END
  FROM public.hiregauge_facet_norms n
  WHERE n.agency_id = p_agency AND n.facet = p_facet;
$$;

CREATE OR REPLACE FUNCTION public.hiregauge_candidate_facet_percentiles(
  p_candidate_id uuid)
RETURNS TABLE(facet text, percentile int) LANGUAGE sql STABLE AS $$
  WITH cand AS (
    SELECT agency_id, achievement_striving, self_discipline, emotional_stability,
      dutifulness, customer_orientation, self_efficacy, proactive_personality,
      cautiousness, anxiety, friendliness, anger, cooperation, trust,
      dispositional_optimism, political_skill_networking, enterprising,
      sincerity, fairness, greed_avoidance, assertiveness, compassion,
      competitiveness, learning_goal_orientation, prove_goal_orientation,
      avoid_goal_orientation
    FROM public.hiring_candidates WHERE id = p_candidate_id
  ),
  unpivoted AS (
    SELECT c.agency_id, v.facet, v.raw
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
  SELECT u.facet, public.hiregauge_facet_percentile(u.agency_id, u.facet, u.raw)
  FROM unpivoted u;
$$;

GRANT EXECUTE ON FUNCTION public.hiregauge_normal_cdf(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hiregauge_facet_percentile(uuid, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hiregauge_candidate_facet_percentiles(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.hiregauge_candidate_facet_percentiles(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.hiregauge_facet_percentile(uuid, text, numeric) FROM anon;
