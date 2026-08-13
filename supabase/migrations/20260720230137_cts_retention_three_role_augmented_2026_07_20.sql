-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-20 23:01:37 UTC (ledger name: cts_retention_three_role_augmented_2026_07_20) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260720230137.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Install augmented service formula into three retention role-fit functions.
-- Base: reverse-engineered vendor SERVICE OS (R²=0.9999, 20/20 exact match on 20-cand cohort).
-- Per-role augmentation: linear trait weights + Analytical bell curve + role-specific LSS tweaks.

CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    -- BASE SERVICE FORMULA
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
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0
      END
    -- RECEPTION AUGMENTATION
    + ( 0.15) * compassion
    + ( 0.10) * deadline_motivation
    + ( 0.10) * assertiveness
    + ( 0.10) * optimism
    + (-0.10) * recognition_drive
    + (-0.10) * independent_spirit
    + (-0.003) * (analytical - 45) * (analytical - 45)
    + CASE
        WHEN lss_verbal_speed_seconds IS NOT NULL
        THEN (-0.5) * (GREATEST(0, 20 - lss_verbal_speed_seconds) - GREATEST(0, 15 - lss_verbal_speed_seconds))
        ELSE 0
      END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    -- BASE SERVICE FORMULA
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
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0
      END
    -- ESCALATION AUGMENTATION
    + ( 0.20) * compassion
    + ( 0.15) * assertiveness
    + ( 0.10) * independent_spirit
    + ( 0.10) * belief_in_others
    + (-0.15) * deadline_motivation
    + (-0.10) * optimism
    + (-0.10) * self_promotion
    + (-0.10) * recognition_drive
    + (-0.003) * (analytical - 65) * (analytical - 65)
    + CASE
        WHEN lss_problem_solving_speed_seconds IS NOT NULL
        THEN 0.491987 * lss_problem_solving_speed_seconds  -- cancel base pSpd penalty (slow thinking is OK here)
        ELSE 0
      END
  ))::int);
$fn$;

CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL,
  lss_problem_solving_accuracy integer DEFAULT NULL, lss_math_speed_seconds integer DEFAULT NULL,
  lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
  SELECT GREATEST(0, LEAST(100, ROUND(
    -- BASE SERVICE FORMULA
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
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL
         AND lss_problem_solving_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL
         AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL
        THEN
            (-16.002241) * GREATEST(0, 8 - lss_verbal_accuracy)
          + ( -5.792535) * GREATEST(0, lss_verbal_accuracy - 9)
          + ( -3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)
          + (  0.975415) * lss_math_speed_seconds
          + ( -0.732130) * GREATEST(0, 15 - lss_verbal_speed_seconds)
          + ( -0.491987) * lss_problem_solving_speed_seconds
        ELSE 0
      END
    -- SUPPORT AUGMENTATION
    + ( 0.15) * independent_spirit
    + ( 0.15) * deadline_motivation
    + (-0.15) * compassion
    + (-0.10) * optimism
    + (-0.10) * self_promotion
    + (-0.10) * recognition_drive
    + (-0.003) * (analytical - 75) * (analytical - 75)
    + CASE
        WHEN lss_math_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
         AND lss_verbal_accuracy IS NOT NULL
        THEN
            (-2.0)      * GREATEST(0, 8 - lss_math_accuracy)  -- add support-specific mAcc penalty
          + (-3.541895) * GREATEST(0, 9 - lss_problem_solving_accuracy)  -- doubles base pAcc penalty
          + CASE WHEN (lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy) >= 30 THEN 5.0 ELSE 0.0 END
        ELSE 0
      END
  ))::int);
$fn$;

COMMENT ON FUNCTION public.cts_retention_reception_os IS
'Reception role-fit (0-100). Base=vendor SERVICE OS formula (R²=0.9999, 20/20 exact on 20-cand cohort). Aug: +Compassion +DeadlineMotivation +Assertiveness +Optimism -RecognitionDrive -IndependentSpirit; Analytical bell-curve @45; verbal-speed penalty threshold shifted 15s->20s. High volume, warm, cross-sell-capable.';

COMMENT ON FUNCTION public.cts_retention_escalation_os IS
'Escalation role-fit (0-100). Base=vendor SERVICE OS. Aug: ++Compassion +Assertiveness +IndependentSpirit +BeliefInOthers -DeadlineMotivation -Optimism -SelfPromotion -RecognitionDrive; Analytical bell-curve @65; personal-solving speed penalty neutralized (slow=OK). Deep unravelers under sustained hostility.';

COMMENT ON FUNCTION public.cts_retention_support_os IS
'Support role-fit (0-100). Base=vendor SERVICE OS. Aug: +IndependentSpirit +DeadlineMotivation -Compassion -Optimism -SelfPromotion -RecognitionDrive; Analytical bell-curve @75; math-accuracy penalty added, problem-solving-accuracy penalty doubled, +5 bonus for total-accuracy>=30. Back-office precision work.';
