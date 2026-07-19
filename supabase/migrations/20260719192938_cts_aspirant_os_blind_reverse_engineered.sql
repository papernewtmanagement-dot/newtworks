-- Replaces Model B (post-Cassandra-fix, R^2=0.95) with blind-reverse-engineered
-- clean fit derived from Compare_Report_aspirant.xlsx (Gmail msg 19f4cb70fe9f76c2).
-- Fit: R^2=0.998846, max_err(raw)=0.5336, 19/20 rounded exact on n=20 cohort.
-- Shape: intercept + 9 traits + 8 LSS piecewise + tAcc raw linear = 18 features.
-- 15-arg signature preserved.

CREATE OR REPLACE FUNCTION public.cts_aspirant_os(
  deadline_motivation integer,
  recognition_drive integer,
  assertiveness integer,
  independent_spirit integer,
  analytical integer,
  compassion integer,
  self_promotion integer,
  belief_in_others integer,
  optimism integer,
  lss_math_accuracy integer DEFAULT NULL::integer,
  lss_verbal_accuracy integer DEFAULT NULL::integer,
  lss_problem_solving_accuracy integer DEFAULT NULL::integer,
  lss_math_speed_seconds integer DEFAULT NULL::integer,
  lss_verbal_speed_seconds integer DEFAULT NULL::integer,
  lss_problem_solving_speed_seconds integer DEFAULT NULL::integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (-50.3562)
    + ( 0.0766) * deadline_motivation
    + ( 0.2184) * recognition_drive
    + (-0.2455) * assertiveness
    + ( 0.2491) * independent_spirit
    + ( 0.1280) * analytical
    + ( 0.1877) * compassion
    + (-0.2082) * self_promotion
    + ( 0.2811) * belief_in_others
    + ( 0.4193) * optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-1.1006) * GREATEST(0, lss_math_accuracy - 9)
          + ( 8.0071) * GREATEST(0, 9 - lss_math_accuracy)
          + (-4.1538) * GREATEST(0, lss_verbal_accuracy - 10)
          + (-2.7236) * GREATEST(0, 8 - lss_problem_solving_accuracy)
          + ( 0.2827) * GREATEST(0, lss_math_speed_seconds - 26)
          + (-1.6613) * GREATEST(0, 24 - lss_verbal_speed_seconds)
          + (-0.2591) * GREATEST(0, lss_problem_solving_speed_seconds - 40)
          + (-0.8319) * GREATEST(0, 30 - lss_problem_solving_speed_seconds)
          + ( 1.7512) * (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        ELSE 0
      END
  ))::int);
$function$;
