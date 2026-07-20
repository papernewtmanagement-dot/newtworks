-- Migration: refit cts_sales_outbound_os with n=21 cohort (Priscilla Brito added)
--
-- Origin: 2026-07-20. Priscilla Brito vendor OS(CTS+LSS) = 54 (verified from her
-- Compare Report PDF in Drive). Prior n=20 fit predicted her at 34 — 20-point
-- out-of-sample miss. Refitting with Priscilla as candidate #21 pulls her within
-- ~3 points of target and preserves team-member scores within ±5 of prior values.
--
-- Shape unchanged: intercept + 9 traits + 12 binary above/below LSS indicators.
-- Coefficients: OLS on n=21 with intercept preserved. Zero-variance directions
-- (mAcc>11 impossible; mSpd>50, vSpd>52, pSpd<17 empty in cohort) retain the
-- Peter-directed extrapolation values from the original 2026-07-19 fit.
--
-- Fit quality (n=21):
--   R² = 0.9589   MAE = 1.44   max_err = 4.33 (William Shue)
-- vs prior n=20 fit R² = 0.9963 / MAE 0.45 / max_err 1.0 (which was overfit —
-- Priscilla's 20-point out-of-sample miss proved it).
--
-- Signature preserved (15 args). Frontend + router (cts_best_fit_role) untouched.

CREATE OR REPLACE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
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
    (47.624905)
    + (0.214598)  * deadline_motivation
    + (0.030108)  * recognition_drive
    + (-0.128545) * assertiveness
    + (0.246099)  * independent_spirit
    + (-0.100272) * analytical
    + (0.069266)  * compassion
    + (-0.146738) * self_promotion
    + (0.082984)  * belief_in_others
    + (0.092536)  * optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (0)          * (CASE WHEN lss_math_accuracy > 11 THEN 1 ELSE 0 END)
          + (-8.625687)  * (CASE WHEN lss_math_accuracy < 10 THEN 1 ELSE 0 END)
          + (-13.784758) * (CASE WHEN lss_verbal_accuracy > 10 THEN 1 ELSE 0 END)
          + (-6.655170)  * (CASE WHEN lss_verbal_accuracy < 8 THEN 1 ELSE 0 END)
          + (-1.714980)  * (CASE WHEN lss_problem_solving_accuracy > 9 THEN 1 ELSE 0 END)
          + (-8.122059)  * (CASE WHEN lss_problem_solving_accuracy < 7 THEN 1 ELSE 0 END)
          + (-3.0)       * (CASE WHEN lss_math_speed_seconds > 50 THEN 1 ELSE 0 END)
          + (4.848970)   * (CASE WHEN lss_math_speed_seconds < 32 THEN 1 ELSE 0 END)
          + (-4.0)       * (CASE WHEN lss_verbal_speed_seconds > 52 THEN 1 ELSE 0 END)
          + (-11.344265) * (CASE WHEN lss_verbal_speed_seconds < 20 THEN 1 ELSE 0 END)
          + (-1.597418)  * (CASE WHEN lss_problem_solving_speed_seconds > 77 THEN 1 ELSE 0 END)
          + (2.0)        * (CASE WHEN lss_problem_solving_speed_seconds < 17 THEN 1 ELSE 0 END)
        ELSE 0
      END
  ))::int);
$function$;
