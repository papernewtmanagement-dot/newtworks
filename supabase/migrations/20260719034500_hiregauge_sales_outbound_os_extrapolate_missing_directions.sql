-- Extrapolate 3 direction coefficients the 20-sample cohort didn't cover:
--   mSpd > 50 (too slow on math)     : -3 pts   (parallels mSpd < 32 near-zero + slowness penalty pattern)
--   vSpd > 52 (too slow on verbal)   : -4 pts   (parallels vSpd < 20 = -7.74; slow less penalized than fast for verbal)
--   pSpd < 17 (very fast on PS)      : +2 pts   (parallels pSpd > 77 = -2.77; decisive on PS is good for outbound)
-- mAcc > 11 stays 0 (impossible; max score is 11).
-- All other coefficients unchanged from blind reverse-engineered fit.
CREATE OR REPLACE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL,
  lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL,
  lss_problem_solving_speed_seconds integer DEFAULT NULL
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (38.715365559693)
    + (0.199406238822)  * deadline_motivation
    + (-0.022253649097) * recognition_drive
    + (-0.133470552026) * assertiveness
    + (0.238836867052)  * independent_spirit
    + (-0.128923704938) * analytical
    + (0.183323317733)  * compassion
    + (-0.163341048302) * self_promotion
    + (0.105278960095)  * belief_in_others
    + (0.174880044199)  * optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (0)                 * (CASE WHEN lss_math_accuracy > 11 THEN 1 ELSE 0 END)
          + (-4.913544004058)   * (CASE WHEN lss_math_accuracy < 10 THEN 1 ELSE 0 END)
          + (-13.099933748201)  * (CASE WHEN lss_verbal_accuracy > 10 THEN 1 ELSE 0 END)
          + (-1.929426666290)   * (CASE WHEN lss_verbal_accuracy < 8 THEN 1 ELSE 0 END)
          + (0.855175224367)    * (CASE WHEN lss_problem_solving_accuracy > 9 THEN 1 ELSE 0 END)
          + (-14.668091731924)  * (CASE WHEN lss_problem_solving_accuracy < 7 THEN 1 ELSE 0 END)
          + (-3.0)              * (CASE WHEN lss_math_speed_seconds > 50 THEN 1 ELSE 0 END)
          + (-0.154704481324)   * (CASE WHEN lss_math_speed_seconds < 32 THEN 1 ELSE 0 END)
          + (-4.0)              * (CASE WHEN lss_verbal_speed_seconds > 52 THEN 1 ELSE 0 END)
          + (-7.743052643064)   * (CASE WHEN lss_verbal_speed_seconds < 20 THEN 1 ELSE 0 END)
          + (-2.766907143434)   * (CASE WHEN lss_problem_solving_speed_seconds > 77 THEN 1 ELSE 0 END)
          + (2.0)               * (CASE WHEN lss_problem_solving_speed_seconds < 17 THEN 1 ELSE 0 END)
        ELSE 0
      END
  ))::int);
$function$;
