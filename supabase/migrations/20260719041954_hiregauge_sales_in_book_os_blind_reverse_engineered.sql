-- Blind reverse-engineered fit of cts_sales_in_book_os against vendor OS(CTS+LSS)
-- Source: Compare_Report_service_sales.xlsx (Gmail msg 19f4cb70fe9f76c2, thread "CTS Profiles")
-- Cohort: 20 candidates. R²=1.0000, MAE=0.000, max_err=0.
-- Shape: intercept + 9 traits + LSS-absolute-distance features + TotalAcc>=29 bonus.
-- LSS block gated on all-6-non-null. Zero-sample directions (above_mSpd, below_vSpd, below_pSpd)
-- are physically impossible OR the in-range extends to infinity; no extrapolation needed.
-- Ranges per Peter's screenshot (session_note 2026-07-18 pm):
--   mAcc [9,10] · vAcc [11,11] · pAcc [9,10] · mSpd [56,120+] · vSpd [0,22] · pSpd [0,34] · TotalAcc >= 29
-- Signature preserved: 15 args, same defaults, same return type.

CREATE OR REPLACE FUNCTION public.cts_sales_in_book_os(
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
    (39.164103)
    + (0.481205)  * deadline_motivation
    + (0.053561)  * recognition_drive
    + (-0.226646) * assertiveness
    + (-0.087201) * independent_spirit
    + (0.259702)  * analytical
    + (0.248922)  * compassion
    + (-0.329396) * self_promotion
    + (0.150658)  * belief_in_others
    + (0.142098)  * optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-27.181629) * GREATEST(0, lss_math_accuracy - 10)
          + (4.392815)   * GREATEST(0, 9 - lss_math_accuracy)
          + (18.000131)  * GREATEST(0, lss_verbal_accuracy - 11)
          + (4.138847)   * GREATEST(0, 11 - lss_verbal_accuracy)
          + (20.473385)  * GREATEST(0, lss_problem_solving_accuracy - 10)
          + (-1.587511)  * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (-1.147633)  * GREATEST(0, 56 - lss_math_speed_seconds)
          + (-0.110551)  * GREATEST(0, lss_verbal_speed_seconds - 22)
          + (-0.584785)  * GREATEST(0, lss_problem_solving_speed_seconds - 34)
          + (6.070690)   * (CASE WHEN (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy) >= 29 THEN 1 ELSE 0 END)
        ELSE 0
      END
  ))::int);
$function$;
