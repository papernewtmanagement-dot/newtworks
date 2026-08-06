-- Fix: _assessment_character_parts (shared "concern" sub-score, used by both
-- paths via NULL-safe partial average) referenced belief_in_others, an
-- old-only column just dropped. Remove it from the formula -- concern now
-- averages over compassion, cooperation, trust (still NULL-safe partial avg).
CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
 RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
 LANGUAGE sql
 STABLE
AS $function$
  WITH f AS (
    SELECT hc.compassion::numeric           AS compassion,
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
