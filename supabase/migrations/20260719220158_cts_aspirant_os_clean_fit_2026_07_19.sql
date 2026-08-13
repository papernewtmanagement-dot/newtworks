-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-19 22:01:58 UTC (ledger name: cts_aspirant_os_clean_fit_2026_07_19) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260719220158.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.cts_aspirant_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL,
  lss_problem_solving_speed_seconds integer DEFAULT NULL)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (-50.356174)
    + (0.076612)  * deadline_motivation
    + (0.218384)  * recognition_drive
    + (-0.245510) * assertiveness
    + (0.249107)  * independent_spirit
    + (0.127994)  * analytical
    + (0.187740)  * compassion
    + (-0.208204) * self_promotion
    + (0.281091)  * belief_in_others
    + (0.419319)  * optimism
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-1.100594)  * GREATEST(0, lss_math_accuracy - 9)
          + (8.007058)   * GREATEST(0, 9 - lss_math_accuracy)
          + (-4.153796)  * GREATEST(0, lss_verbal_accuracy - 10)
          + (-2.723616)  * GREATEST(0, 8 - lss_problem_solving_accuracy)
          + (0.282701)   * GREATEST(0, lss_math_speed_seconds - 26)
          + (-1.661326)  * GREATEST(0, 24 - lss_verbal_speed_seconds)
          + (-0.259091)  * GREATEST(0, lss_problem_solving_speed_seconds - 40)
          + (-0.831866)  * GREATEST(0, 30 - lss_problem_solving_speed_seconds)
          + (1.751151)   * (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        ELSE 0
      END
  ))::int);
$function$;

COMMENT ON FUNCTION public.cts_aspirant_os IS 'Blind reverse-engineered from vendor Compare_Report_aspirant.xlsx (2026-07-19). R2=0.9988, max_err=0.53, 19/20 exact after rounding. Clean formula: 9 traits + LSS piecewise above/below + tAcc raw linear (no threshold flags, no accounting workarounds). pSpd breakpoints [30,40] data-driven (Peter screenshot said 67-120 but produces R2=0.987 only). Replaces prior Model B. One rounding-boundary miss: Bob Williams predicted 56 vs vendor 57.';
