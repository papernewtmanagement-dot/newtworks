-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 16:25:56 UTC (ledger name: install_cts_os_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710162556.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- CTS role compatibility (OS) functions
-- Reverse-engineered from Cheetah Compare Reports (2026-07-10)
-- Each takes 9 primary traits + optional LSS (accuracy, speed). Returns int 0-100.
-- With LSS: R²~0.90, max err ~6pts. Traits-only: R²~0.85, max err ~10pts.

CREATE OR REPLACE FUNCTION public.cts_sales_os(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int,
  lss_accuracy int DEFAULT NULL, lss_speed int DEFAULT NULL
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (6.471910) + (0.125853)*deadline_motivation + (0.057017)*recognition_drive + (0.087795)*assertiveness + (-0.010998)*independent_spirit + (-0.184444)*analytical + (0.028288)*compassion + (-0.044198)*self_promotion + (0.070897)*belief_in_others + (0.115570)*optimism + (0.646056)*lss_accuracy + (0.294447)*lss_speed
      ELSE
        (22.857171) + (0.138199)*deadline_motivation + (0.083892)*recognition_drive + (0.100960)*assertiveness + (0.087151)*independent_spirit + (-0.200504)*analytical + (0.037691)*compassion + (-0.025924)*self_promotion + (0.144147)*belief_in_others + (0.101358)*optimism
    END
  ))::int);
$$;

CREATE OR REPLACE FUNCTION public.cts_service_os(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int,
  lss_accuracy int DEFAULT NULL, lss_speed int DEFAULT NULL
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (26.737855) + (-0.211294)*deadline_motivation + (0.099734)*recognition_drive + (0.203253)*assertiveness + (-0.046158)*independent_spirit + (-0.120847)*analytical + (-0.136944)*compassion + (0.109643)*self_promotion + (0.017709)*belief_in_others + (0.020116)*optimism + (0.954199)*lss_accuracy + (0.009134)*lss_speed
      ELSE
        (64.829540) + (-0.318684)*deadline_motivation + (-0.096038)*recognition_drive + (-0.075983)*assertiveness + (0.196425)*independent_spirit + (0.066890)*analytical + (-0.026908)*compassion + (-0.134179)*self_promotion + (-0.067665)*belief_in_others + (0.055102)*optimism
    END
  ))::int);
$$;

CREATE OR REPLACE FUNCTION public.cts_service_sales_os(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int,
  lss_accuracy int DEFAULT NULL, lss_speed int DEFAULT NULL
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (35.152315) + (0.013628)*deadline_motivation + (0.188268)*recognition_drive + (0.048592)*assertiveness + (-0.048348)*independent_spirit + (-0.141002)*analytical + (-0.074373)*compassion + (-0.063929)*self_promotion + (0.018233)*belief_in_others + (0.037204)*optimism + (0.606300)*lss_accuracy + (-0.141140)*lss_speed
      ELSE
        (59.066333) + (0.052250)*deadline_motivation + (0.173319)*recognition_drive + (-0.041146)*assertiveness + (-0.026856)*independent_spirit + (-0.225873)*analytical + (-0.073068)*compassion + (-0.064484)*self_promotion + (-0.005304)*belief_in_others + (0.023996)*optimism
    END
  ))::int);
$$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_os(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int,
  lss_accuracy int DEFAULT NULL, lss_speed int DEFAULT NULL
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    CASE
      WHEN lss_accuracy IS NOT NULL AND lss_speed IS NOT NULL THEN
        (-1.716507) + (-0.053875)*deadline_motivation + (0.121198)*recognition_drive + (-0.115261)*assertiveness + (0.136612)*independent_spirit + (0.231194)*analytical + (0.125989)*compassion + (-0.068408)*self_promotion + (0.209681)*belief_in_others + (0.164544)*optimism + (0.565452)*lss_accuracy + (-0.213406)*lss_speed
      ELSE
        (7.686460) + (-0.055694)*deadline_motivation + (0.110884)*recognition_drive + (-0.079010)*assertiveness + (0.146746)*independent_spirit + (0.114941)*analytical + (0.119808)*compassion + (0.007410)*self_promotion + (0.203894)*belief_in_others + (0.159133)*optimism
    END
  ))::int);
$$;

COMMENT ON FUNCTION public.cts_sales_os IS 'CTS sales role compatibility score, reverse-engineered via OLS on 20 Cheetah Compare Report candidates (2026-07-10). Traits-only R²~0.86 max err ~10; +LSS R²~0.89 max err ~5.';
COMMENT ON FUNCTION public.cts_service_os IS 'CTS service role compatibility score. Traits-only R²~0.87 max err ~9; +LSS R²~0.87 max err ~6.';
COMMENT ON FUNCTION public.cts_service_sales_os IS 'CTS service+sales role compatibility score. Traits-only R²~0.92 max err ~9; +LSS R²~0.90 max err ~6.';
COMMENT ON FUNCTION public.cts_aspirant_os IS 'CTS aspirant (agent) role compatibility score. Traits-only R²~0.82 max err ~7; +LSS R²~0.91 max err ~7.';

-- Best-fit function: runs an assessment through all 4 role functions and returns the top match
CREATE OR REPLACE FUNCTION public.cts_best_fit_role(p_assessment_id uuid)
RETURNS TABLE(
  best_role text,
  best_os int,
  sales_os int,
  service_os int,
  service_sales_os int,
  aspirant_os int
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  t RECORD;
  s int; sv int; ss int; a int;
  best_r text; best_o int;
  avg_speed int;
BEGIN
  SELECT 
    deadline_motivation, recognition_drive, assertiveness, independent_spirit,
    analytical, compassion, self_promotion, belief_in_others, optimism,
    lss_total_accuracy,
    NULLIF((COALESCE(lss_math_speed_seconds, 0) + COALESCE(lss_verbal_speed_seconds, 0) + COALESCE(lss_problem_solving_speed_seconds, 0))
       / NULLIF((CASE WHEN lss_math_speed_seconds IS NOT NULL THEN 1 ELSE 0 END
              + CASE WHEN lss_verbal_speed_seconds IS NOT NULL THEN 1 ELSE 0 END
              + CASE WHEN lss_problem_solving_speed_seconds IS NOT NULL THEN 1 ELSE 0 END), 0), 0) AS avg_speed
  INTO t
  FROM public.team_assessments
  WHERE id = p_assessment_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;
  
  -- If any primary trait is NULL, we cannot compute — return NULLs
  IF t.deadline_motivation IS NULL OR t.optimism IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int;
    RETURN;
  END IF;
  
  s  := public.cts_sales_os(t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_total_accuracy, t.avg_speed);
  sv := public.cts_service_os(t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_total_accuracy, t.avg_speed);
  ss := public.cts_service_sales_os(t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_total_accuracy, t.avg_speed);
  a  := public.cts_aspirant_os(t.deadline_motivation, t.recognition_drive, t.assertiveness, t.independent_spirit, t.analytical, t.compassion, t.self_promotion, t.belief_in_others, t.optimism, t.lss_total_accuracy, t.avg_speed);
  
  best_o := GREATEST(s, sv, ss, a);
  best_r := CASE 
    WHEN best_o = s  THEN 'sales'
    WHEN best_o = sv THEN 'service'
    WHEN best_o = ss THEN 'service_sales'
    ELSE 'aspirant'
  END;
  
  RETURN QUERY SELECT best_r, best_o, s, sv, ss, a;
END;
$$;

COMMENT ON FUNCTION public.cts_best_fit_role IS 'Given an assessment id, runs its trait scores through all 4 role compatibility functions and returns the top-fit role along with all 4 role scores. Uses lss_total_accuracy + average of 3 lss section speeds when available for the +LSS variant.';
