-- HireGauge Step D follow-up: hand-spec fns preserve production behavior.
--
-- Prior migration (20260718210000) switched the 7 CTS OS fn signatures to
-- per-sub-test but treated speed as SUM inside the 5 hand-spec fns, which
-- produced dramatically lower scores than production had shown (cts_best_fit_role
-- was passing avg_speed = SUM/3 as lss_speed before this refactor).
--
-- Fix: use AVG (SUM/3) inside the 5 hand-spec fns to exactly reproduce the
-- pre-refactor production output. Accuracy stays as SUM (matches the original
-- behavior where cts_best_fit_role passed lss_total_accuracy = SUM as lss_accuracy).
--
-- sales_outbound + aspirant left alone — their new Model C fits use per-sub-test
-- values directly (each at natural scale), no aggregation convention applies.
--
-- Signature unchanged from 20260718210000, so CREATE OR REPLACE works without
-- DROP-first.

CREATE OR REPLACE FUNCTION public.cts_sales_inbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (8.500000) + (0.080000)*deadline_motivation + (0.057017)*recognition_drive + (0.070000)*assertiveness + (0.010000)*independent_spirit + (-0.140000)*analytical + (0.080000)*compassion + (-0.045000)*self_promotion + (0.075000)*belief_in_others + (0.150000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*((lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)::numeric / 3.0)
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.083892)*recognition_drive + (0.080000)*assertiveness + (0.030000)*independent_spirit + (-0.150000)*analytical + (0.100000)*compassion + (-0.030000)*self_promotion + (0.150000)*belief_in_others + (0.150000)*optimism
    END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_sales_in_book_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (8.500000) + (0.070000)*deadline_motivation + (0.057017)*recognition_drive + (0.050000)*assertiveness + (0.005000)*independent_spirit + (0.060000)*analytical + (0.130000)*compassion + (-0.045000)*self_promotion + (0.150000)*belief_in_others + (0.100000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*((lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)::numeric / 3.0)
      ELSE
        (25.000000) + (0.080000)*deadline_motivation + (0.083892)*recognition_drive + (0.060000)*assertiveness + (0.020000)*independent_spirit + (0.050000)*analytical + (0.150000)*compassion + (-0.030000)*self_promotion + (0.180000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (12.000000) + (0.050000)*deadline_motivation + (0.040000)*recognition_drive + (0.015000)*assertiveness + (0.005000)*independent_spirit + (0.030000)*analytical + (0.150000)*compassion + (-0.100000)*self_promotion + (0.100000)*belief_in_others + (0.150000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*((lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)::numeric / 3.0)
      ELSE
        (30.000000) + (0.060000)*deadline_motivation + (0.050000)*recognition_drive + (0.020000)*assertiveness + (0.010000)*independent_spirit + (0.030000)*analytical + (0.180000)*compassion + (-0.100000)*self_promotion + (0.120000)*belief_in_others + (0.180000)*optimism
    END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (10.000000) + (0.080000)*deadline_motivation + (0.060000)*recognition_drive + (0.060000)*assertiveness + (0.010000)*independent_spirit + (0.100000)*analytical + (0.110000)*compassion + (-0.040000)*self_promotion + (0.120000)*belief_in_others + (0.100000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*((lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)::numeric / 3.0)
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.070000)*recognition_drive + (0.070000)*assertiveness + (0.020000)*independent_spirit + (0.100000)*analytical + (0.130000)*compassion + (-0.030000)*self_promotion + (0.140000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (10.000000) + (0.090000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.030000)*independent_spirit + (0.180000)*analytical + (0.060000)*compassion + (-0.150000)*self_promotion + (0.060000)*belief_in_others + (0.080000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*((lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)::numeric / 3.0)
      ELSE
        (25.000000) + (0.100000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.050000)*independent_spirit + (0.200000)*analytical + (0.070000)*compassion + (-0.170000)*self_promotion + (0.070000)*belief_in_others + (0.080000)*optimism
    END
  ))::int);
$fn$;
