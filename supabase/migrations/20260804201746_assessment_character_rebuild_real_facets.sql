-- Rebuild the Character cell of the assessment layer on real personality facets.
-- Peter directive 2026-08-04: wire it up properly; blanks are acceptable.
--
-- WHAT CAME OUT. Two of the three old ingredients were response-style indices, not
-- traits: honesty was derived from response_distortion, and work ethic from
-- reliability. Ones, Viswesvaran & Reiss 1996 (JAP) found social-desirability scales
-- predict neither job performance nor counterproductive behavior, and recommend
-- against correcting for impression management in selection. Both are gone.
--
-- WHAT GOES IN, per operational_rule "Construct-axis research verdict 2026-08-04":
--   Concern for Others     -> compassion, cooperation, trust
--   Hard Work Ethic        -> self_discipline, achievement_striving, dutifulness
--   Personal Responsibility-> dutifulness, self_efficacy
--   Honesty                -> no facet exists. Belongs to the interview and reference
--                             layers (direct questions, observed conduct), not here.
-- The four component names are Peter's own, from core_principles #550. dutifulness
-- feeding two components is intentional, not a duplication bug.
--
-- Grounds for building character off personality facets at all: Ones, Viswesvaran &
-- Schmidt 1993 (JAP Monograph 78:679-703, 665 coefficients, N=576,460) put integrity
-- test operational validity at .41 for job performance and .47 for counterproductive
-- behavior; Ones & Viswesvaran 1998 show personality-based integrity measures are a
-- compound of conscientiousness, agreeableness and emotional stability.
--
-- TWO JUDGMENT CALLS, STATED PLAINLY RATHER THAN BURIED:
-- 1. belief_in_others is kept as a stand-in for trust when trust is null. It is the
--    older instrument's nearest equivalent and is already populated for all 53
--    assessed candidates. Dropping it would have blanked Concern for Others for every
--    existing record for no gain.
-- 2. Component averaging is unit-weighted. This replaces the previous 0.7/0.3
--    compassion/belief split. Unit weights are the accurate choice absent a large
--    local validation sample (Wainer 1976), so this is not a simplification.
--
-- Components with no data return NULL and are simply absent from the average. Today
-- that means Concern for Others carries the cell alone, and Hard Work Ethic and
-- Personal Responsibility are blank until candidates take the current assessment.
-- That is the intended behavior: blank beats a number derived from the wrong input.
--
-- impression_management remains a FLAG only and is never scored into anything.

-- Shared component math, so the function and the view cannot drift apart.
CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
LANGUAGE sql STABLE AS $function$
  WITH f AS (
    SELECT hc.compassion::numeric                                AS compassion,
           hc.cooperation::numeric                               AS cooperation,
           COALESCE(hc.trust, hc.belief_in_others)::numeric       AS trust_or_belief,
           hc.self_discipline::numeric                            AS self_discipline,
           hc.achievement_striving::numeric                        AS achievement_striving,
           hc.dutifulness::numeric                                AS dutifulness,
           hc.self_efficacy::numeric                              AS self_efficacy
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    round((COALESCE(compassion,0) + COALESCE(cooperation,0) + COALESCE(trust_or_belief,0))
      / NULLIF((compassion IS NOT NULL)::int + (cooperation IS NOT NULL)::int
             + (trust_or_belief IS NOT NULL)::int, 0), 2),
    round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
      / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
             + (dutifulness IS NOT NULL)::int, 0), 2),
    round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
      / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2)
  FROM f;
$function$;

CREATE OR REPLACE FUNCTION public.assessment_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  SELECT round(
    (COALESCE(p.concern,0) + COALESCE(p.work_ethic,0) + COALESCE(p.personal_responsibility,0))
    / NULLIF((p.concern IS NOT NULL)::int
           + (p.work_ethic IS NOT NULL)::int
           + (p.personal_responsibility IS NOT NULL)::int, 0), 2)
  FROM public._assessment_character_parts(p_candidate_id) p;
$function$;

GRANT EXECUTE ON FUNCTION public._assessment_character_parts(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assessment_character(uuid) TO anon, authenticated, service_role;
