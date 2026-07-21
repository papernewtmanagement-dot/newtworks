-- Migration: cts_sales_inbound_os_2026_07_20
-- Applied 2026-07-20 via Supabase MCP apply_migration.
-- Purpose: replace placeholder cts_sales_inbound_os with aspirant-base + warm-inbound augmentation.
-- Design: no inbound-specific vendor score exists (Compare_Report_78313.xlsx has single OS column
-- used to fit outbound). Base = aspirant formula (neutral sales, R^2=0.9988 vs vendor).
-- Layer = warm-inbound trait adjustments + character floors on Assertiveness and Compassion.
-- Signature: 15 args identical to the other 6 cts_*_os functions (best_fit_role compatibility).
CREATE OR REPLACE FUNCTION public.cts_sales_inbound_os(
  deadline_motivation integer,
  recognition_drive integer,
  assertiveness integer,
  independent_spirit integer,
  analytical integer,
  compassion integer,
  self_promotion integer,
  belief_in_others integer,
  optimism integer,
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
AS $fn$
  WITH raw AS (
    SELECT GREATEST(0, LEAST(100, ROUND(
      -- ASPIRANT BASE (reverse-engineered 2026-07-19, R^2=0.9988, 19/20 rounded exact vs vendor)
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
      -- WARM-INBOUND AUGMENTATION (judgment-informed; recalibrate after 6-12 months of hires)
      + (0.15)   * compassion            -- warmer than cold-caller
      + (0.15)   * belief_in_others      -- consultative, trusts customer's stated need
      + (0.10)   * analytical            -- matches products to stated needs
      + (0.05)   * optimism              -- upbeat but not fake
      + (-0.10)  * recognition_drive     -- less chase-the-numbers than outbound
      + (-0.10)  * self_promotion        -- less pushy, more listener
      + (-0.05)  * deadline_motivation   -- softer pace than cold-calling grind
      + (-0.003) * (analytical - 60) * (analytical - 60)  -- sweet spot at 60; too low or too high hurts
    ))::int) AS score
  )
  SELECT CASE
    WHEN assertiveness < 30 THEN LEAST(score, 40)  -- floor: can't close a sale without assertiveness
    WHEN compassion < 30    THEN LEAST(score, 40)  -- floor: cold-caller demeanor kills warm leads
    ELSE score
  END FROM raw;
$fn$;

COMMENT ON FUNCTION public.cts_sales_inbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer) IS
'Sales inbound (warm lead) role-fit score 0-100. Aspirant base + warm-inbound augmentation. Augmentation weights are judgment-informed (no vendor data separates inbound from outbound); recalibrate after 6-12 months of on-the-job performance. Ships 2026-07-20.';
