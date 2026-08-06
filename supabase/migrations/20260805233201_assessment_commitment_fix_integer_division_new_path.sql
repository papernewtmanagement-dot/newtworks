-- Fix: new-instrument branch of assessment_commitment did integer division.
-- All six facet columns are integer; sum(int)/count(int) truncates the decimal
-- (e.g. 539/6 = 89 instead of 89.83) before round() ever sees it. Old-instrument
-- branch already casts ::numeric and is unchanged. Caught 2026-08-05 on the first
-- new-instrument completion (owner smoke test); no real candidates affected.
-- Value is computed at read time (view + verdict RPCs) — no stored copies, no backfill.
CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  -- New-instrument (achievement_striving IS NOT NULL) branch: partial-average
  -- (COALESCE/NULLIF count-of-non-null pattern, same as _assessment_character_parts)
  -- over [enterprising, achievement_striving, competitiveness,
  -- prove_goal_orientation, learning_goal_orientation, (100 - avoid_goal_orientation)].
  -- Numerator cast ::numeric (2026-08-05) — facet columns are integer and the
  -- uncast sum/count silently truncated fractional means.
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
         + COALESCE(100 - hc.avoid_goal_orientation, 0))::numeric
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
