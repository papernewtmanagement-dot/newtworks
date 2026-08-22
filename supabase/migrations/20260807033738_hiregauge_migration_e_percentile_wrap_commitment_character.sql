CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: inputs now read as
  -- percentiles against hiregauge_facet_norms rather than raw 0-100 columns.
  -- Formula shape unchanged. avoid_goal_orientation reversal (100 - x)
  -- applied AFTER percentile conversion. Divisor counts NON-NULL
  -- PERCENTILES, not non-null raw columns (E.1 ruling) -- a facet whose
  -- norm is absent (e.g. parked competitiveness) contributes 0 to both
  -- numerator and divisor rather than silently deflating the score; when
  -- its norm eventually seeds, it re-enters both automatically.
  WITH c AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, 'enterprising', hc.enterprising) AS p_enterprising,
      public.hiregauge_facet_percentile(hc.agency_id, 'achievement_striving', hc.achievement_striving) AS p_achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, 'competitiveness', hc.competitiveness) AS p_competitiveness,
      public.hiregauge_facet_percentile(hc.agency_id, 'prove_goal_orientation', hc.prove_goal_orientation) AS p_prove_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, 'learning_goal_orientation', hc.learning_goal_orientation) AS p_learning_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, 'avoid_goal_orientation', hc.avoid_goal_orientation) AS p_avoid_goal_orientation
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
      AND hc.achievement_striving IS NOT NULL
  )
  SELECT
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
    , 2)
  FROM c;
$function$;

CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
 RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: percentile-wrapped,
  -- same divisor rule as assessment_commitment (E.1) applied for future-
  -- proofing even though every facet here has a seeded norm today.
  WITH f AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, 'compassion', hc.compassion)::numeric AS compassion,
      public.hiregauge_facet_percentile(hc.agency_id, 'cooperation', hc.cooperation)::numeric AS cooperation,
      public.hiregauge_facet_percentile(hc.agency_id, 'trust', hc.trust)::numeric AS trust,
      public.hiregauge_facet_percentile(hc.agency_id, 'self_discipline', hc.self_discipline)::numeric AS self_discipline,
      public.hiregauge_facet_percentile(hc.agency_id, 'achievement_striving', hc.achievement_striving)::numeric AS achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, 'dutifulness', hc.dutifulness)::numeric AS dutifulness,
      public.hiregauge_facet_percentile(hc.agency_id, 'self_efficacy', hc.self_efficacy)::numeric AS self_efficacy
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    round((COALESCE(compassion,0) + COALESCE(cooperation,0) + COALESCE(trust,0))
      / NULLIF((compassion IS NOT NULL)::int
             + (cooperation IS NOT NULL)::int + (trust IS NOT NULL)::int, 0), 2),
    round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
      / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
             + (dutifulness IS NOT NULL)::int, 0), 2),
    round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
      / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2)
  FROM f;
$function$;
