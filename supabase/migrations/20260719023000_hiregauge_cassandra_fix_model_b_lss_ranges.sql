-- ============================================================================
-- MIGRATION: 20260719023000_hiregauge_cassandra_fix_model_b_lss_ranges
-- ============================================================================
-- Fix Cassandra 100/100 on sales_outbound + aspirant caused by Model C's
-- linear LSS branch extrapolating wildly on out-of-training-range inputs
-- (her LSS speeds are 3-5x outside training cohort max).
--
-- Root cause: Model C empirical fit at n=20 with 15 features (4 residual df)
-- produced coefficients whose SIGNS contradict vendor's published ideal ranges
-- (e.g. sales_outbound m_spd coefficient +0.84, meaning "slower = better sales" —
-- vendor design says sales math wants MODERATE 32-50s). Wrong sign at extreme
-- input = wild extrapolation.
--
-- Fix (Model B): Replace empirical LSS branch on sales_outbound + aspirant
-- with vendor-designed in-range flag bonus. 6 binary flags per role (3 acc +
-- 3 speed sub-tests against vendor's published ideal range). Bonus centered
-- at 3/6 flags = 0, mapping ±15 pts. Bounded → structurally cannot extrapolate.
--
-- Vendor ranges (from HireGauge Compare Report screenshots, session_note
-- "2026-07-18 pm — HireGauge Step D findings + per-sub-test LSS pivot"):
--   SALES:    MathAcc 10-11, VerbAcc 8-10, PSAcc 7-9,
--             MathSpd 32-50, VerbSpd 20-52, PSSpd 17-77
--   ASPIRANT: MathAcc 9-9,   VerbAcc 5-10, PSAcc 8-11,
--             MathSpd 4-26,  VerbSpd 24-66, PSSpd 67-999 (vendor shows "120+" open)
--
-- Trait-only ELSE branch preserved (used when LSS not available).
-- Function signature preserved: (9 CTS + 6 per-sub-test) — no frontend impact.
-- The 5 hand-spec fns (sales_inbound, sales_in_book, retention_reception/
-- escalation/support) are UNCHANGED — they work correctly under LSS extremes
-- because their coefficients are directionally correct (accuracy positive,
-- speed negative, matching vendor design).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- cts_sales_outbound_os
-- ---------------------------------------------------------------------------
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
  -- Model B: trait-only formula + LSS in-range flag bonus (bounded -15 to +15)
  -- SALES vendor ranges: MathAcc 10-11, VerbAcc 8-10, PSAcc 7-9,
  --                      MathSpd 32-50, VerbSpd 20-52, PSSpd 17-77
  SELECT GREATEST(0, LEAST(100, ROUND(
    -- trait-only base (unchanged from prior fit)
    (22.857171)
    + (0.138199) * deadline_motivation
    + (0.083892) * recognition_drive
    + (0.100960) * assertiveness
    + (0.087151) * independent_spirit
    + (-0.200504) * analytical
    + (0.037691) * compassion
    + (-0.025924) * self_promotion
    + (0.144147) * belief_in_others
    + (0.101358) * optimism
    +
    -- LSS bonus: only applied when all 6 sub-tests present
    CASE
      WHEN lss_math_accuracy IS NOT NULL
       AND lss_verbal_accuracy IS NOT NULL
       AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL
       AND lss_verbal_speed_seconds IS NOT NULL
       AND lss_problem_solving_speed_seconds IS NOT NULL
      THEN
        (
          -- Count in-range sub-tests (6 flags)
          (CASE WHEN lss_math_accuracy BETWEEN 10 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 8  AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 7 AND 9 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 32 AND 50 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 20 AND 52 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 17 AND 77 THEN 1 ELSE 0 END)
          - 3.0
        ) / 3.0 * 15.0
      ELSE 0
    END
  ))::int);
$function$;

-- ---------------------------------------------------------------------------
-- cts_aspirant_os
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_aspirant_os(
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
AS $function$
  -- Model B: trait-only formula + LSS in-range flag bonus (bounded -15 to +15)
  -- ASPIRANT vendor ranges: MathAcc 9-9,  VerbAcc 5-10, PSAcc 8-11,
  --                         MathSpd 4-26, VerbSpd 24-66, PSSpd 67-999 (vendor "120+" open)
  SELECT GREATEST(0, LEAST(100, ROUND(
    -- trait-only base (unchanged from prior fit)
    (7.686460)
    + (-0.055694) * deadline_motivation
    + (0.110884) * recognition_drive
    + (-0.079010) * assertiveness
    + (0.146746) * independent_spirit
    + (0.114941) * analytical
    + (0.119808) * compassion
    + (0.007410) * self_promotion
    + (0.203894) * belief_in_others
    + (0.159133) * optimism
    +
    CASE
      WHEN lss_math_accuracy IS NOT NULL
       AND lss_verbal_accuracy IS NOT NULL
       AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL
       AND lss_verbal_speed_seconds IS NOT NULL
       AND lss_problem_solving_speed_seconds IS NOT NULL
      THEN
        (
          (CASE WHEN lss_math_accuracy BETWEEN 9  AND 9  THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_accuracy BETWEEN 5 AND 10 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_accuracy BETWEEN 8 AND 11 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_math_speed_seconds BETWEEN 4  AND 26 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_verbal_speed_seconds BETWEEN 24 AND 66 THEN 1 ELSE 0 END)
        + (CASE WHEN lss_problem_solving_speed_seconds BETWEEN 67 AND 999 THEN 1 ELSE 0 END)
          - 3.0
        ) / 3.0 * 15.0
      ELSE 0
    END
  ))::int);
$function$;

COMMENT ON FUNCTION public.cts_sales_outbound_os IS 'HireGauge role compatibility for sales_outbound. Model B (2026-07-19): trait-only fit + LSS in-range flag bonus. Bonus bounded ±15 pts across 6 vendor-designed sub-test range flags. Replaces empirical Model C LSS branch which extrapolated wildly on out-of-training-range inputs.';
COMMENT ON FUNCTION public.cts_aspirant_os IS 'HireGauge role compatibility for aspirant. Model B (2026-07-19): trait-only fit + LSS in-range flag bonus. Bonus bounded ±15 pts across 6 vendor-designed sub-test range flags. Replaces empirical Model C LSS branch which extrapolated wildly on out-of-training-range inputs.';
