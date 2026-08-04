-- Restore belief_in_others to the concern-for-others element of assessment_character.
-- The 2026-08-04 rebuild (20260804201746 / 20260804202221) built concern from
-- compassion + cooperation + trust only. cooperation and trust are NULL on all 195
-- candidate rows (zero v2 assessments exist), so concern collapsed to compassion alone
-- and belief_in_others -- which IS populated on all 53 assessed candidates -- was ignored.
-- belief_in_others is an agreeableness-family trait and was in the approved spec.
CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
 RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH f AS (
    SELECT hc.compassion::numeric           AS compassion,
           hc.belief_in_others::numeric     AS belief_in_others,
           hc.cooperation::numeric          AS cooperation,
           hc.trust::numeric                AS trust,
           hc.self_discipline::numeric      AS self_discipline,
           hc.achievement_striving::numeric AS achievement_striving,
           hc.dutifulness::numeric          AS dutifulness,
           hc.self_efficacy::numeric        AS self_efficacy
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    round((COALESCE(compassion,0) + COALESCE(belief_in_others,0)
         + COALESCE(cooperation,0) + COALESCE(trust,0))
      / NULLIF((compassion IS NOT NULL)::int + (belief_in_others IS NOT NULL)::int
             + (cooperation IS NOT NULL)::int + (trust IS NOT NULL)::int, 0), 2),
    round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
      / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
             + (dutifulness IS NOT NULL)::int, 0), 2),
    round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
      / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2)
  FROM f;
$function$;
