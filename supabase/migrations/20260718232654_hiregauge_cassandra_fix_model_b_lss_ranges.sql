-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 23:26:54 UTC (ledger name: hiregauge_cassandra_fix_model_b_lss_ranges) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718232654.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Model B: replace Model C empirical LSS branches on sales_outbound + aspirant
-- with vendor-range flag bonus. Fixes Cassandra 100/100 extrapolation.
-- See mirrored migration file for full commentary.

CREATE OR REPLACE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL::integer,
  lss_verbal_accuracy integer DEFAULT NULL::integer,
  lss_problem_solving_accuracy integer DEFAULT NULL::integer,
  lss_math_speed_seconds integer DEFAULT NULL::integer,
  lss_verbal_speed_seconds integer DEFAULT NULL::integer,
  lss_problem_solving_speed_seconds integer DEFAULT NULL::integer)
RETURNS integer LANGUAGE sql IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (22.857171) + (0.138199)*deadline_motivation + (0.083892)*recognition_drive
    + (0.100960)*assertiveness + (0.087151)*independent_spirit
    + (-0.200504)*analytical + (0.037691)*compassion + (-0.025924)*self_promotion
    + (0.144147)*belief_in_others + (0.101358)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 10 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 8 AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 7 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 32 AND 50 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 20 AND 52 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 17 AND 77 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL::integer,
  lss_verbal_accuracy integer DEFAULT NULL::integer,
  lss_problem_solving_accuracy integer DEFAULT NULL::integer,
  lss_math_speed_seconds integer DEFAULT NULL::integer,
  lss_verbal_speed_seconds integer DEFAULT NULL::integer,
  lss_problem_solving_speed_seconds integer DEFAULT NULL::integer)
RETURNS integer LANGUAGE sql IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (7.686460) + (-0.055694)*deadline_motivation + (0.110884)*recognition_drive
    + (-0.079010)*assertiveness + (0.146746)*independent_spirit
    + (0.114941)*analytical + (0.119808)*compassion + (0.007410)*self_promotion
    + (0.203894)*belief_in_others + (0.159133)*optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN (
          (CASE WHEN lss_math_accuracy BETWEEN 9 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 5 AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 8 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 4 AND 26 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 24 AND 66 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 67 AND 999 THEN 1 ELSE 0 END)
          - 3.0) / 3.0 * 15.0
        ELSE 0
      END
  ))::int);
$function$;

COMMENT ON FUNCTION public.cts_sales_outbound_os IS 'HireGauge role compat sales_outbound. Model B (2026-07-19): trait-only + LSS in-range flag bonus (bounded +/-15 across 6 vendor-designed sub-test range flags). Replaces Model C empirical LSS branch (extrapolated wildly on out-of-training-range inputs).';
COMMENT ON FUNCTION public.cts_aspirant_os IS 'HireGauge role compat aspirant. Model B (2026-07-19): trait-only + LSS in-range flag bonus (bounded +/-15 across 6 vendor-designed sub-test range flags). Replaces Model C empirical LSS branch (extrapolated wildly on out-of-training-range inputs).';
