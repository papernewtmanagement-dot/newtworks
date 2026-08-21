-- Step A of HireGauge accuracy audit fix sequence.
-- Bug: 6 of 7 CTS OS functions have +0.294447 * lss_speed_seconds in LSS branch.
-- LSS speed is in seconds where higher = slower. Positive coefficient rewards
-- slowness — inverted. Only cts_aspirant_os had correct sign (-0.213406) from
-- its independent empirical fit. The identical +0.294447 across the other 6
-- indicates a shared hand-spec bolt-on, not empirical output.
-- Fix: flip sign on lss_speed term in the LSS branch of all 6 non-aspirant OS
-- functions. Trait coefficients + intercepts + lss_accuracy coefficient unchanged.

CREATE OR REPLACE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (6.471910) + (0.125853)*deadline_motivation + (0.057017)*recognition_drive + (0.087795)*assertiveness + (-0.010998)*independent_spirit + (-0.184444)*analytical + (0.028288)*compassion + (-0.044198)*self_promotion + (0.070897)*belief_in_others + (0.115570)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (22.857171) + (0.138199)*deadline_motivation + (0.083892)*recognition_drive + (0.100960)*assertiveness + (0.087151)*independent_spirit + (-0.200504)*analytical + (0.037691)*compassion + (-0.025924)*self_promotion + (0.144147)*belief_in_others + (0.101358)*optimism
    END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_sales_inbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (8.500000) + (0.080000)*deadline_motivation + (0.057017)*recognition_drive + (0.070000)*assertiveness + (0.010000)*independent_spirit + (-0.140000)*analytical + (0.080000)*compassion + (-0.045000)*self_promotion + (0.075000)*belief_in_others + (0.150000)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.083892)*recognition_drive + (0.080000)*assertiveness + (0.030000)*independent_spirit + (-0.150000)*analytical + (0.100000)*compassion + (-0.030000)*self_promotion + (0.150000)*belief_in_others + (0.150000)*optimism
    END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_sales_in_book_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (8.500000) + (0.070000)*deadline_motivation + (0.057017)*recognition_drive + (0.050000)*assertiveness + (0.005000)*independent_spirit + (0.060000)*analytical + (0.130000)*compassion + (-0.045000)*self_promotion + (0.150000)*belief_in_others + (0.100000)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (25.000000) + (0.080000)*deadline_motivation + (0.083892)*recognition_drive + (0.060000)*assertiveness + (0.020000)*independent_spirit + (0.050000)*analytical + (0.150000)*compassion + (-0.030000)*self_promotion + (0.180000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (12.000000) + (0.050000)*deadline_motivation + (0.040000)*recognition_drive + (0.015000)*assertiveness + (0.005000)*independent_spirit + (0.030000)*analytical + (0.150000)*compassion + (-0.100000)*self_promotion + (0.100000)*belief_in_others + (0.150000)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (30.000000) + (0.060000)*deadline_motivation + (0.050000)*recognition_drive + (0.020000)*assertiveness + (0.010000)*independent_spirit + (0.030000)*analytical + (0.180000)*compassion + (-0.100000)*self_promotion + (0.120000)*belief_in_others + (0.180000)*optimism
    END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (10.000000) + (0.080000)*deadline_motivation + (0.060000)*recognition_drive + (0.060000)*assertiveness + (0.010000)*independent_spirit + (0.100000)*analytical + (0.110000)*compassion + (-0.040000)*self_promotion + (0.120000)*belief_in_others + (0.100000)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.070000)*recognition_drive + (0.070000)*assertiveness + (0.020000)*independent_spirit + (0.100000)*analytical + (0.130000)*compassion + (-0.030000)*self_promotion + (0.140000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL::integer, lss_speed integer DEFAULT NULL::integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (10.000000) + (0.090000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.030000)*independent_spirit + (0.180000)*analytical + (0.060000)*compassion + (-0.150000)*self_promotion + (0.060000)*belief_in_others + (0.080000)*optimism + (0.646056)*lss_accuracy + (-0.294447)*lss_speed
      ELSE
        (25.000000) + (0.100000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.050000)*independent_spirit + (0.200000)*analytical + (0.070000)*compassion + (-0.170000)*self_promotion + (0.070000)*belief_in_others + (0.080000)*optimism
    END
  ))::int);
$function$;
