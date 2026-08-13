-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-20 23:04:04 UTC (ledger name: cts_retention_three_role_augmented_v2_2026_07_20) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260720230404.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- V2: reduce escalation pSpd cancellation from full to quarter (was giving too-large boost to slow-thinkers).
-- Add character-floor caps: role score capped at 40 if a non-negotiable trait fails minimum.

CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  WITH raw AS (
    SELECT GREATEST(0, LEAST(100, ROUND(
      45.925324
      + (-0.122413) * deadline_motivation
      + ( 0.018921) * recognition_drive
      + (-0.818205) * assertiveness
      + ( 0.189229) * independent_spirit
      + (-0.018449) * analytical
      + (-0.010927) * compassion
      + ( 1.016070) * self_promotion
      + (-0.324571) * belief_in_others
      + ( 0.222401) * optimism
      + (-0.008396) * self_promotion * self_promotion
      + ( 0.004797) * belief_in_others * belief_in_others
      + ( 0.005530) * assertiveness * assertiveness
      + CASE WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
              AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
              AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0 END
      + ( 0.15) * compassion
      + ( 0.10) * deadline_motivation
      + ( 0.10) * assertiveness
      + ( 0.10) * optimism
      + (-0.10) * recognition_drive
      + (-0.10) * independent_spirit
      + (-0.003) * (analytical - 45) * (analytical - 45)
      + CASE WHEN lss_verbal_speed_seconds IS NOT NULL
        THEN (-0.5) * (GREATEST(0, 20 - lss_verbal_speed_seconds) - GREATEST(0, 15 - lss_verbal_speed_seconds))
        ELSE 0 END
    ))::int) AS score
  )
  SELECT CASE
    WHEN optimism < 40 THEN LEAST(score, 40)   -- reception floor: front-desk demeanor non-negotiable
    ELSE score
  END FROM raw;
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  WITH raw AS (
    SELECT GREATEST(0, LEAST(100, ROUND(
      45.925324
      + (-0.122413) * deadline_motivation
      + ( 0.018921) * recognition_drive
      + (-0.818205) * assertiveness
      + ( 0.189229) * independent_spirit
      + (-0.018449) * analytical
      + (-0.010927) * compassion
      + ( 1.016070) * self_promotion
      + (-0.324571) * belief_in_others
      + ( 0.222401) * optimism
      + (-0.008396) * self_promotion * self_promotion
      + ( 0.004797) * belief_in_others * belief_in_others
      + ( 0.005530) * assertiveness * assertiveness
      + CASE WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
              AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
              AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0 END
      + ( 0.20) * compassion
      + ( 0.15) * assertiveness
      + ( 0.10) * independent_spirit
      + ( 0.10) * belief_in_others
      + (-0.15) * deadline_motivation
      + (-0.10) * optimism
      + (-0.10) * self_promotion
      + (-0.10) * recognition_drive
      + (-0.003) * (analytical - 65) * (analytical - 65)
      + CASE WHEN lss_problem_solving_speed_seconds IS NOT NULL
        THEN 0.122997 * lss_problem_solving_speed_seconds  -- quarter-cancel base pSpd penalty (slow=OK but not rewarded)
        ELSE 0 END
    ))::int) AS score
  )
  SELECT CASE
    WHEN compassion < 40 THEN LEAST(score, 40)      -- escalation floor: needs empathy under fire
    WHEN assertiveness < 40 THEN LEAST(score, 40)   -- and firmness to hold ground
    ELSE score
  END FROM raw;
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  WITH raw AS (
    SELECT GREATEST(0, LEAST(100, ROUND(
      45.925324
      + (-0.122413) * deadline_motivation
      + ( 0.018921) * recognition_drive
      + (-0.818205) * assertiveness
      + ( 0.189229) * independent_spirit
      + (-0.018449) * analytical
      + (-0.010927) * compassion
      + ( 1.016070) * self_promotion
      + (-0.324571) * belief_in_others
      + ( 0.222401) * optimism
      + (-0.008396) * self_promotion * self_promotion
      + ( 0.004797) * belief_in_others * belief_in_others
      + ( 0.005530) * assertiveness * assertiveness
      + CASE WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
              AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
              AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0 END
      + ( 0.15) * independent_spirit
      + ( 0.15) * deadline_motivation
      + (-0.15) * compassion
      + (-0.10) * optimism
      + (-0.10) * self_promotion
      + (-0.10) * recognition_drive
      + (-0.003) * (analytical - 75) * (analytical - 75)
      + CASE WHEN lss_math_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
              AND lss_verbal_accuracy IS NOT NULL
        THEN
            (-2.0)      * GREATEST(0, 8 - lss_math_accuracy)
          + (-3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + CASE WHEN (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy) >= 30 THEN 5.0 ELSE 0.0 END
        ELSE 0 END
    ))::int) AS score
  )
  SELECT CASE
    WHEN analytical < 40 THEN LEAST(score, 40)   -- support floor: needs analytical minimum
    WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
     AND lss_problem_solving_accuracy IS NOT NULL
     AND (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy) < 25
     THEN LEAST(score, 40)   -- support floor: total test accuracy 25+ non-negotiable
    ELSE score
  END FROM raw;
$fn$;
