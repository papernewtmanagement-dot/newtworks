CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  -- New-instrument (achievement_striving IS NOT NULL) branch: partial-average
  -- (COALESCE/NULLIF count-of-non-null pattern, same as _assessment_character_parts)
  -- over [enterprising, achievement_striving, competitiveness,
  -- prove_goal_orientation, learning_goal_orientation, (100 - avoid_goal_orientation)].
  -- Unit weights per Wainer 1976 ("Estimating Coefficients in Linear Models:
  -- It Don't Make No Nevermind") -- simple happens to be accurate here.
  --   achievement_striving        -- Vinchur, Schippmann, Switzer & Roth 1998,
  --                                  Journal of Applied Psychology 83(4) 586-597:
  --                                  strongest single objective-sales predictor (rho .41).
  --   competitiveness             -- Brown, Cron & Slocum 1998, Journal of Marketing
  --                                  62(4) 88-98: trait competitiveness, status-striving route.
  --   prove_goal_orientation      -- Barrick, Stewart & Piotrowski 2002, Journal of
  --                                  Applied Psychology 87(1) 43-51: status striving
  --                                  (recognition-expressed route) mediates personality
  --                                  -> sales performance.
  --   learning_goal_orientation   -- VandeWalle 1997, Educational and Psychological
  --                                  Measurement 57(6) 995-1015, scored positively;
  --                                  Payne, Youngcourt & Beaubien 2007, Journal of
  --                                  Applied Psychology 92(1) 128-150: learning
  --                                  orientation rho +.18.
  --   avoid_goal_orientation      -- reversed (100 - value): Payne, Youngcourt &
  --                                  Beaubien 2007 found performance-avoid orientation
  --                                  rho -.11 (negative), hence flipped before averaging.
  --   enterprising                -- Nye, Su, Rounds & Drasgow 2012, Perspectives on
  --                                  Psychological Science 7(4) 384-403: vocational
  --                                  interest-job congruence rho .20.
  -- Old-instrument (deadline_motivation IS NOT NULL) branch is byte-identical to
  -- before -- dual-path scoring is a standing instruction, not touched by this build.
  SELECT CASE
    WHEN hc.achievement_striving IS NOT NULL THEN
      round(
        (COALESCE(hc.enterprising,0) + COALESCE(hc.achievement_striving,0)
         + COALESCE(hc.competitiveness,0) + COALESCE(hc.prove_goal_orientation,0)
         + COALESCE(hc.learning_goal_orientation,0)
         + COALESCE(100 - hc.avoid_goal_orientation, 0))
        / NULLIF(
            (hc.enterprising IS NOT NULL)::int + (hc.achievement_striving IS NOT NULL)::int
            + (hc.competitiveness IS NOT NULL)::int + (hc.prove_goal_orientation IS NOT NULL)::int
            + (hc.learning_goal_orientation IS NOT NULL)::int + (hc.avoid_goal_orientation IS NOT NULL)::int,
          0)
      , 2)
    WHEN hc.deadline_motivation IS NOT NULL THEN
      round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0, 2)
    ELSE NULL
  END
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$function$;

-- Motivation-type breakdown per Peter's locked Commitment definition (part 3:
-- motivation TYPE, graded per type rather than a single primary driver).
-- COMPETITIVE / INCOME / DUTY / RECOGNITION are Peter's four confirmed types
-- (Final Interview manual scorecard). Assessment-side coverage today only
-- reaches achievement, competitive, and recognition (via prove_goal_orientation
-- as the status-striving/recognition-expressed proxy) and learning/avoid goal
-- orientation. Income and duty are interview-only BY DESIGN per the locked
-- Commitment definition (part 2 buy-in / normative commitment cannot be
-- measured pre-hire on a self-report instrument) -- nulls here are correct
-- and must not be filled with assessment proxies.
CREATE OR REPLACE FUNCTION public.newtworks_motivation_types(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  SELECT jsonb_build_object(
    'achievement', hc.achievement_striving,
    'competitive', hc.competitiveness,
    'recognition', hc.prove_goal_orientation,
    'learning',    hc.learning_goal_orientation,
    'avoid',       hc.avoid_goal_orientation,
    'income',      NULL,
    'duty',        NULL
  )
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$function$;
