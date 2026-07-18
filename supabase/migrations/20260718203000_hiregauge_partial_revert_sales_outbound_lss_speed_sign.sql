-- HireGauge Step D partial revert: restore vendor's empirical +0.294447 lss_speed
-- coefficient on cts_sales_outbound_os only. Step A (commit 7453df25) flipped
-- signs on all 6 non-aspirant fns; that was correct for the 5 hand-spec fns but
-- broke the empirical sales_outbound R²=0.894 fit. This mig restores only
-- sales_outbound; the other 5 hand-spec fns keep their negative-signed lss_speed.
-- Coefficients otherwise unchanged from the OLS re-fit (matches installed DB
-- values to 6 decimals per aggregate-Speed OLS validation, 2026-07-18 pm).

CREATE OR REPLACE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer,
  recognition_drive integer,
  assertiveness integer,
  independent_spirit integer,
  analytical integer,
  compassion integer,
  self_promotion integer,
  belief_in_others integer,
  optimism integer,
  lss_accuracy integer DEFAULT NULL::integer,
  lss_speed integer DEFAULT NULL::integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (6.471910) + (0.125853)*deadline_motivation + (0.057017)*recognition_drive + (0.087795)*assertiveness + (-0.010998)*independent_spirit + (-0.184444)*analytical + (0.028288)*compassion + (-0.044198)*self_promotion + (0.070897)*belief_in_others + (0.115570)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (22.857171) + (0.138199)*deadline_motivation + (0.083892)*recognition_drive + (0.100960)*assertiveness + (0.087151)*independent_spirit + (-0.200504)*analytical + (0.037691)*compassion + (-0.025924)*self_promotion + (0.144147)*belief_in_others + (0.101358)*optimism
    END
  ))::int);
$function$;
