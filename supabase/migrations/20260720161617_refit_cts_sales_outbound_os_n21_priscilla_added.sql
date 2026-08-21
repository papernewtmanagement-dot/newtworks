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
