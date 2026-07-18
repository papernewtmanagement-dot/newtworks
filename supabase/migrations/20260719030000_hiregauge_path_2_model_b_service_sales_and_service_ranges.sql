-- Path 2: Model B (vendor in-range flag bonus) replaces empirical Model C LSS branch
-- on the 4 hand-spec role fns: cts_sales_in_book_os + cts_retention_{reception,escalation,support}_os.
--
-- Structural design (identical to Cassandra-fix migration 20260719023000 for sales_outbound + aspirant):
-- - Single trait block (unconditional, taken from the fn's original LSS-ABSENT ELSE branch)
-- - LSS bonus CASE gated on all 6 LSS args non-null; bonus = ((flags - 3.0) / 3.0) * 15.0 → bounded ±15 pts
-- - Overall result clipped 0..100 via GREATEST/LEAST/ROUND
-- - Structurally immune to extrapolation on out-of-cohort LSS inputs
--
-- Vendor Compare Report ideal ranges (captured 2026-07-18 pm, source: peter.story.yrru@statefarm.com
-- Compare_Report_service_sales.xlsx + Compare_Report_service.xlsx):
--   SERVICE_SALES (→ cts_sales_in_book_os):
--     MathAcc 9-10 · VerbAcc 11-11 · PSAcc 9-10 | MathSpd 56-999 · VerbSpd 0-22 · PSSpd 0-34
--   SERVICE (→ cts_retention_reception/escalation/support_os, all 3 share):
--     MathAcc 8-11 · VerbAcc 8-9 · PSAcc 9-11   | MathSpd 48-999 · VerbSpd 15-39 · PSSpd 0-46
--
-- "999" upper bound = vendor "120+" open range (matches sales_outbound PSSpd 17-77 → aspirant PSSpd 67-999
-- convention from the Cassandra-fix migration).
--
-- Function signatures preserved (9 CTS + 6 per-sub-test LSS args, 15 total, all LSS nullable).
-- No frontend impact. No hiregauge_evaluate_candidate / hiregauge_composite_recommendation changes.

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
    (25.000000) + (0.080000)*deadline_motivation + (0.083892)*recognition_drive
    + (0.060000)*assertiveness + (0.020000)*independent_spirit
    + (0.050000)*analytical + (0.150000)*compassion + (-0.030000)*self_promotion
    + (0.180000)*belief_in_others + (0.100000)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 9 AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 11 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 9 AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 56 AND 999 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 0 AND 22 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 0 AND 34 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;


CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
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
    (30.000000) + (0.060000)*deadline_motivation + (0.050000)*recognition_drive
    + (0.020000)*assertiveness + (0.010000)*independent_spirit
    + (0.030000)*analytical + (0.180000)*compassion + (-0.100000)*self_promotion
    + (0.120000)*belief_in_others + (0.180000)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 8 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 8 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 9 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 48 AND 999 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 15 AND 39 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 0 AND 46 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;


CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
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
    (25.000000) + (0.090000)*deadline_motivation + (0.070000)*recognition_drive
    + (0.070000)*assertiveness + (0.020000)*independent_spirit
    + (0.100000)*analytical + (0.130000)*compassion + (-0.030000)*self_promotion
    + (0.140000)*belief_in_others + (0.100000)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 8 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 8 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 9 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 48 AND 999 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 15 AND 39 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 0 AND 46 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;


CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
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
    (25.000000) + (0.100000)*deadline_motivation + (0.030000)*recognition_drive
    + (0.010000)*assertiveness + (0.050000)*independent_spirit
    + (0.200000)*analytical + (0.070000)*compassion + (-0.170000)*self_promotion
    + (0.070000)*belief_in_others + (0.080000)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 8 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 8 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 9 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 48 AND 999 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 15 AND 39 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 0 AND 46 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;
