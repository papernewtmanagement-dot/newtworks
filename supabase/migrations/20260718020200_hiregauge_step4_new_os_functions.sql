-- HireGauge Sprint Step 4: 5 new OS functions (v1 hand-spec)
-- Roles: sales_inbound, sales_in_book, retention_reception, retention_escalation, retention_support
-- Regression scaffold from cts_sales_outbound_os. Coefficients adjusted per trait signatures
-- in sprint spec (session_note "2026-07-17 late night — HireGauge 7-role expansion scoping").
-- Refine after seat-holder cohort accumulates.

-- SALES - INBOUND
-- Warm-inbound seat: structure supplied, less DM/IS drive needed, boost warm-relational traits.
-- Base: sales_outbound. Δ: dampen DM+IS, lift CO+OP.
CREATE OR REPLACE FUNCTION public.cts_sales_inbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL, lss_speed integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (8.500000) + (0.080000)*deadline_motivation + (0.057017)*recognition_drive + (0.070000)*assertiveness + (0.010000)*independent_spirit + (-0.140000)*analytical + (0.080000)*compassion + (-0.045000)*self_promotion + (0.075000)*belief_in_others + (0.150000)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.083892)*recognition_drive + (0.080000)*assertiveness + (0.030000)*independent_spirit + (-0.150000)*analytical + (0.100000)*compassion + (-0.030000)*self_promotion + (0.150000)*belief_in_others + (0.150000)*optimism
    END
  ))::int);
$$;

-- SALES - IN-BOOK
-- Relational sell to existing renewal book: cross-sell + retention watchfulness.
-- Base: sales_outbound. Δ: dampen DM+IS, flip AN positive, lift CO+BO.
CREATE OR REPLACE FUNCTION public.cts_sales_in_book_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL, lss_speed integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (8.500000) + (0.070000)*deadline_motivation + (0.057017)*recognition_drive + (0.050000)*assertiveness + (0.005000)*independent_spirit + (0.060000)*analytical + (0.130000)*compassion + (-0.045000)*self_promotion + (0.150000)*belief_in_others + (0.100000)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (25.000000) + (0.080000)*deadline_motivation + (0.083892)*recognition_drive + (0.060000)*assertiveness + (0.020000)*independent_spirit + (0.050000)*analytical + (0.150000)*compassion + (-0.030000)*self_promotion + (0.180000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$$;

-- RETENTION - RECEPTION
-- Front-line warm-facing retention: rapid rapport, routing judgment, composure, pivots.
-- Base: sales_outbound scaffold. Δ: heavy dampen DM+IS, flip AN positive, strong lift CO+OP+BO.
CREATE OR REPLACE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL, lss_speed integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (12.000000) + (0.050000)*deadline_motivation + (0.040000)*recognition_drive + (0.015000)*assertiveness + (0.005000)*independent_spirit + (0.030000)*analytical + (0.150000)*compassion + (-0.100000)*self_promotion + (0.100000)*belief_in_others + (0.150000)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (30.000000) + (0.060000)*deadline_motivation + (0.050000)*recognition_drive + (0.020000)*assertiveness + (0.010000)*independent_spirit + (0.030000)*analytical + (0.180000)*compassion + (-0.100000)*self_promotion + (0.120000)*belief_in_others + (0.180000)*optimism
    END
  ))::int);
$$;

-- RETENTION - ESCALATION
-- Elevated retention with save-selling posture: retention watchfulness + proactive touch.
-- Base: sales_outbound scaffold. Δ: keep DM, dampen IS, flip AN strongly positive, lift CO+BO.
CREATE OR REPLACE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL, lss_speed integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (10.000000) + (0.080000)*deadline_motivation + (0.060000)*recognition_drive + (0.060000)*assertiveness + (0.010000)*independent_spirit + (0.100000)*analytical + (0.110000)*compassion + (-0.040000)*self_promotion + (0.120000)*belief_in_others + (0.100000)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.070000)*recognition_drive + (0.070000)*assertiveness + (0.020000)*independent_spirit + (0.100000)*analytical + (0.130000)*compassion + (-0.030000)*self_promotion + (0.140000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$$;

-- RETENTION - SUPPORT
-- Back-office task-driver: queue throughput + attention to detail.
-- Base: sales_outbound scaffold. Δ: dampen AS+SP, strong lift AN, mild DM+IS.
CREATE OR REPLACE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_accuracy integer DEFAULT NULL, lss_speed integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (10.000000) + (0.090000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.030000)*independent_spirit + (0.180000)*analytical + (0.060000)*compassion + (-0.150000)*self_promotion + (0.060000)*belief_in_others + (0.080000)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (25.000000) + (0.100000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.050000)*independent_spirit + (0.200000)*analytical + (0.070000)*compassion + (-0.170000)*self_promotion + (0.070000)*belief_in_others + (0.080000)*optimism
    END
  ))::int);
$$;

COMMENT ON FUNCTION public.cts_sales_inbound_os IS
  'HireGauge Step 4 v1: Sales-Inbound overall score. Base: sales_outbound scaffold with dampened DM/IS and lifted CO/OP for warm-facing seat.';
COMMENT ON FUNCTION public.cts_sales_in_book_os IS
  'HireGauge Step 4 v1: Sales-In-Book overall score. Base: sales_outbound scaffold with AN flipped positive and lifted CO/BO for relational renewal-book selling.';
COMMENT ON FUNCTION public.cts_retention_reception_os IS
  'HireGauge Step 4 v1: Retention-Reception overall score. Base: sales_outbound scaffold with heavy dampen DM/IS, strong lift CO/OP for front-line warm reception.';
COMMENT ON FUNCTION public.cts_retention_escalation_os IS
  'HireGauge Step 4 v1: Retention-Escalation overall score. Base: sales_outbound scaffold with AN flipped strongly positive, lifted CO/BO for elevated save-posture retention.';
COMMENT ON FUNCTION public.cts_retention_support_os IS
  'HireGauge Step 4 v1: Retention-Support overall score. Base: sales_outbound scaffold with strong AN lift, dampened AS/SP for back-office task-driver seat.';
