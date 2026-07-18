-- HireGauge Step D: rewrite 7 CTS OS fns with per-sub-test LSS signatures
-- Peter approved Path A (rip the bandaid) 2026-07-18 pm.
--
-- CHANGE: signature (9 CTS + agg_acc + agg_speed) -> (9 CTS + 6 per-sub-test)
-- sales_outbound + aspirant: NEW Model C empirical fits (OLS on 20-candidate xlsx cohort, 2026-07-18)
--   - sales_outbound R²=0.9559 (was 0.894 with aggregate speed)
--   - aspirant       R²=0.9813 (was 0.906 with aggregate speed)
-- 5 hand-spec fns (sales_inbound, sales_in_book, retention_reception/escalation/support):
--   preserve existing formulas EXACTLY by computing (m_acc+v_acc+p_acc) and
--   (m_spd+v_spd+p_spd) inline as the aggregate values the hand-spec math expects.
-- cts_best_fit_role: read + pass per-sub-test cols directly; no more avg_speed helper.
--
-- Non-additive; atomic; all in one transaction.

DROP FUNCTION IF EXISTS public.cts_best_fit_role(uuid);
DROP FUNCTION IF EXISTS public.cts_sales_outbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_sales_inbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_sales_in_book_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_reception_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_escalation_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_support_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_aspirant_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);

-- =============================================================================
-- sales_outbound — NEW EMPIRICAL FIT (Model C, R²=0.9559)
-- =============================================================================
CREATE FUNCTION public.cts_sales_outbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (-11.1510) + (0.2094)*deadline_motivation + (0.1369)*recognition_drive + (-0.0950)*assertiveness + (0.1153)*independent_spirit + (-0.3288)*analytical + (0.0047)*compassion + (-0.0629)*self_promotion + (0.1770)*belief_in_others + (0.2970)*optimism
        + (-2.9564)*lss_math_accuracy + (-0.5135)*lss_verbal_accuracy + (2.2362)*lss_problem_solving_accuracy
        + (0.8396)*lss_math_speed_seconds + (1.3203)*lss_verbal_speed_seconds + (-0.1877)*lss_problem_solving_speed_seconds
      ELSE
        (22.857171) + (0.138199)*deadline_motivation + (0.083892)*recognition_drive + (0.100960)*assertiveness + (0.087151)*independent_spirit + (-0.200504)*analytical + (0.037691)*compassion + (-0.025924)*self_promotion + (0.144147)*belief_in_others + (0.101358)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- aspirant — NEW EMPIRICAL FIT (Model C, R²=0.9813)
-- =============================================================================
CREATE FUNCTION public.cts_aspirant_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (-10.1041) + (0.1125)*deadline_motivation + (0.2054)*recognition_drive + (-0.3461)*assertiveness + (0.2574)*independent_spirit + (-0.0341)*analytical + (-0.0276)*compassion + (0.0561)*self_promotion + (0.3423)*belief_in_others + (0.2942)*optimism
        + (-5.5230)*lss_math_accuracy + (1.8669)*lss_verbal_accuracy + (0.0980)*lss_problem_solving_accuracy
        + (1.1116)*lss_math_speed_seconds + (1.4211)*lss_verbal_speed_seconds + (-0.5224)*lss_problem_solving_speed_seconds
      ELSE
        (7.686460) + (-0.055694)*deadline_motivation + (0.110884)*recognition_drive + (-0.079010)*assertiveness + (0.146746)*independent_spirit + (0.114941)*analytical + (0.119808)*compassion + (0.007410)*self_promotion + (0.203894)*belief_in_others + (0.159133)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- sales_inbound — HAND-SPEC (unchanged math; agg computed inline from sub-tests)
-- =============================================================================
CREATE FUNCTION public.cts_sales_inbound_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (8.500000) + (0.080000)*deadline_motivation + (0.057017)*recognition_drive + (0.070000)*assertiveness + (0.010000)*independent_spirit + (-0.140000)*analytical + (0.080000)*compassion + (-0.045000)*self_promotion + (0.075000)*belief_in_others + (0.150000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*(lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.083892)*recognition_drive + (0.080000)*assertiveness + (0.030000)*independent_spirit + (-0.150000)*analytical + (0.100000)*compassion + (-0.030000)*self_promotion + (0.150000)*belief_in_others + (0.150000)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- sales_in_book — HAND-SPEC (unchanged math)
-- =============================================================================
CREATE FUNCTION public.cts_sales_in_book_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (8.500000) + (0.070000)*deadline_motivation + (0.057017)*recognition_drive + (0.050000)*assertiveness + (0.005000)*independent_spirit + (0.060000)*analytical + (0.130000)*compassion + (-0.045000)*self_promotion + (0.150000)*belief_in_others + (0.100000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*(lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)
      ELSE
        (25.000000) + (0.080000)*deadline_motivation + (0.083892)*recognition_drive + (0.060000)*assertiveness + (0.020000)*independent_spirit + (0.050000)*analytical + (0.150000)*compassion + (-0.030000)*self_promotion + (0.180000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- retention_reception — HAND-SPEC (unchanged math)
-- =============================================================================
CREATE FUNCTION public.cts_retention_reception_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (12.000000) + (0.050000)*deadline_motivation + (0.040000)*recognition_drive + (0.015000)*assertiveness + (0.005000)*independent_spirit + (0.030000)*analytical + (0.150000)*compassion + (-0.100000)*self_promotion + (0.100000)*belief_in_others + (0.150000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*(lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)
      ELSE
        (30.000000) + (0.060000)*deadline_motivation + (0.050000)*recognition_drive + (0.020000)*assertiveness + (0.010000)*independent_spirit + (0.030000)*analytical + (0.180000)*compassion + (-0.100000)*self_promotion + (0.120000)*belief_in_others + (0.180000)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- retention_escalation — HAND-SPEC (unchanged math)
-- =============================================================================
CREATE FUNCTION public.cts_retention_escalation_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (10.000000) + (0.080000)*deadline_motivation + (0.060000)*recognition_drive + (0.060000)*assertiveness + (0.010000)*independent_spirit + (0.100000)*analytical + (0.110000)*compassion + (-0.040000)*self_promotion + (0.120000)*belief_in_others + (0.100000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*(lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)
      ELSE
        (25.000000) + (0.090000)*deadline_motivation + (0.070000)*recognition_drive + (0.070000)*assertiveness + (0.020000)*independent_spirit + (0.100000)*analytical + (0.130000)*compassion + (-0.030000)*self_promotion + (0.140000)*belief_in_others + (0.100000)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- retention_support — HAND-SPEC (unchanged math)
-- =============================================================================
CREATE FUNCTION public.cts_retention_support_os(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer,
  lss_math_accuracy integer DEFAULT NULL, lss_verbal_accuracy integer DEFAULT NULL, lss_problem_solving_accuracy integer DEFAULT NULL,
  lss_math_speed_seconds integer DEFAULT NULL, lss_verbal_speed_seconds integer DEFAULT NULL, lss_problem_solving_speed_seconds integer DEFAULT NULL
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_math_accuracy IS NOT NULL AND lss_math_speed_seconds IS NOT NULL THEN
        (10.000000) + (0.090000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.030000)*independent_spirit + (0.180000)*analytical + (0.060000)*compassion + (-0.150000)*self_promotion + (0.060000)*belief_in_others + (0.080000)*optimism
        + (0.646056)*(lss_math_accuracy + lss_verbal_accuracy + lss_problem_solving_accuracy)
        + (-0.294447)*(lss_math_speed_seconds + lss_verbal_speed_seconds + lss_problem_solving_speed_seconds)
      ELSE
        (25.000000) + (0.100000)*deadline_motivation + (0.030000)*recognition_drive + (0.010000)*assertiveness + (0.050000)*independent_spirit + (0.200000)*analytical + (0.070000)*compassion + (-0.170000)*self_promotion + (0.070000)*belief_in_others + (0.080000)*optimism
    END
  ))::int);
$$;

-- =============================================================================
-- cts_best_fit_role — router; reads per-sub-test cols + passes to each OS fn
-- =============================================================================
CREATE FUNCTION public.cts_best_fit_role(p_assessment_id uuid)
RETURNS TABLE(best_role text, best_role_category text, display_label text, best_os integer, sales_outbound_os integer, sales_inbound_os integer, sales_in_book_os integer, retention_reception_os integer, retention_escalation_os integer, retention_support_os integer, aspirant_os integer)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  t RECORD;
  os_so int; os_si int; os_sib int; os_rr int; os_re int; os_rs int; os_asp int;
  best_r text; best_o int;
  best_cat text; best_label text;
BEGIN
  SELECT
    deadline_motivation, recognition_drive, assertiveness, independent_spirit,
    analytical, compassion, self_promotion, belief_in_others, optimism,
    lss_math_accuracy, lss_verbal_accuracy, lss_problem_solving_accuracy,
    lss_math_speed_seconds, lss_verbal_speed_seconds, lss_problem_solving_speed_seconds
  INTO t
  FROM public.hiring_candidates
  WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  IF t.deadline_motivation IS NULL OR t.optimism IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int;
    RETURN;
  END IF;

  os_so  := public.cts_sales_outbound_os      (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_si  := public.cts_sales_inbound_os       (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_sib := public.cts_sales_in_book_os       (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_rr  := public.cts_retention_reception_os (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_re  := public.cts_retention_escalation_os(t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_rs  := public.cts_retention_support_os   (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);
  os_asp := public.cts_aspirant_os            (t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_math_accuracy, t.lss_verbal_accuracy, t.lss_problem_solving_accuracy, t.lss_math_speed_seconds, t.lss_verbal_speed_seconds, t.lss_problem_solving_speed_seconds);

  best_o := GREATEST(os_so, os_si, os_sib, os_rr, os_re, os_rs, os_asp);

  best_r := CASE
    WHEN best_o = os_so  THEN 'sales_outbound'
    WHEN best_o = os_si  THEN 'sales_inbound'
    WHEN best_o = os_sib THEN 'sales_in_book'
    WHEN best_o = os_rr  THEN 'retention_reception'
    WHEN best_o = os_re  THEN 'retention_escalation'
    WHEN best_o = os_rs  THEN 'retention_support'
    ELSE 'aspirant'
  END;

  best_cat := CASE
    WHEN best_r IN ('sales_outbound', 'sales_inbound', 'sales_in_book') THEN 'sales'
    WHEN best_r IN ('retention_reception', 'retention_escalation', 'retention_support') THEN 'retention'
    ELSE 'aspirant'
  END;

  best_label := CASE best_r
    WHEN 'sales_outbound'       THEN 'Sales - Outbound'
    WHEN 'sales_inbound'        THEN 'Sales - Inbound'
    WHEN 'sales_in_book'        THEN 'Sales - In-Book'
    WHEN 'retention_reception'  THEN 'Retention - Reception'
    WHEN 'retention_escalation' THEN 'Retention - Escalation'
    WHEN 'retention_support'    THEN 'Retention - Support'
    ELSE 'Aspirant'
  END;

  RETURN QUERY SELECT
    best_r, best_cat, best_label, best_o,
    os_so, os_si, os_sib, os_rr, os_re, os_rs, os_asp;
END;
$$;
