-- 20260723180000_layer_verdict_functions.sql
-- Peter directive 2026-07-23:
--   * Verdict function per layer (resume, assessment, interview, reference)
--   * One total verdict function
--   * Nature / Nurture / Drivers CELL functions per layer, no columns storing derived scores
--   * Character floor is NOT a gate (principle rewritten same session)
--   * Role arg on assessment + overall verdicts; NULL falls back to best-fit
--   * Math extracted verbatim from v_hiring_candidates + hiregauge_three_construct_verdict

-- ==================== RESUME LAYER CELLS ====================

CREATE OR REPLACE FUNCTION public.resume_nature(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score) / 3.0, 2)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id
    AND hc.res_autonomy_score IS NOT NULL
    AND hc.res_leadership_emergence_score IS NOT NULL
    AND hc.res_interpersonal_substrate_score IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.resume_nurture(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score) / 4.0, 2)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id
    AND hc.res_honesty_score IS NOT NULL
    AND hc.res_concern_for_others_score IS NOT NULL
    AND hc.res_hard_work_ethic_score IS NOT NULL
    AND hc.res_personal_responsibility_score IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.resume_drivers(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score) / 4.0, 2)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id
    AND hc.res_trajectory_direction_score IS NOT NULL
    AND hc.res_coherent_pursuit_score IS NOT NULL
    AND hc.res_follow_through_score IS NOT NULL
    AND hc.res_goal_orientation_score IS NOT NULL;
$$;

-- ==================== ASSESSMENT LAYER CELLS ====================

-- assessment_nature: role-conditional. Returns role's OS integer as numeric.
-- If p_role is NULL, falls back to (target_role → best_fit_role).
CREATE OR REPLACE FUNCTION public.assessment_nature(p_candidate_id uuid, p_role text DEFAULT NULL)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_target text;
  v_bf record;
  v_result numeric;
BEGIN
  IF p_role IS NOT NULL THEN
    v_target := p_role;
  ELSE
    SELECT hc.assessment_target_role INTO v_target
    FROM public.hiring_candidates hc WHERE hc.id = p_candidate_id;
  END IF;

  SELECT * INTO v_bf FROM public.cts_best_fit_role(p_candidate_id);
  IF NOT FOUND THEN RETURN NULL; END IF;

  IF v_target IS NULL THEN v_target := v_bf.best_role; END IF;

  v_result := CASE v_target
    WHEN 'aspirant'             THEN v_bf.aspirant_os
    WHEN 'sales_outbound'       THEN v_bf.sales_outbound_os
    WHEN 'sales_inbound'        THEN v_bf.sales_inbound_os
    WHEN 'sales_in_book'        THEN v_bf.sales_in_book_os
    WHEN 'retention_reception'  THEN v_bf.retention_reception_os
    WHEN 'retention_escalation' THEN v_bf.retention_escalation_os
    WHEN 'retention_support'    THEN v_bf.retention_support_os
    ELSE NULL
  END;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.assessment_nurture(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT public.cts_assessment_nurture(hc.response_distortion, hc.reliability, hc.compassion, hc.belief_in_others)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$$;

CREATE OR REPLACE FUNCTION public.assessment_drivers(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT public.cts_assessment_drivers(hc.deadline_motivation, hc.recognition_drive, hc.independent_spirit)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$$;

-- ==================== INTERVIEW LAYER CELLS ====================

CREATE OR REPLACE FUNCTION public.interview_nature(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(avg((((e.val -> 'scores') -> 'nature') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'nature') ->> 'score') IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.interview_nurture(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(avg((((e.val -> 'scores') -> 'nurture') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'nurture') ->> 'score') IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.interview_drivers(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(avg((((e.val -> 'scores') -> 'drivers') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'drivers') ->> 'score') IS NOT NULL;
$$;

-- ==================== REFERENCE LAYER CELLS ====================

-- ref_nature/nurture/drivers are 1-10 manual scores; scaled ×10 to 0-100 for verdict math.
CREATE OR REPLACE FUNCTION public.reference_nature(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT (hc.ref_nature * 10)::numeric
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.ref_nature IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.reference_nurture(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT (hc.ref_nurture * 10)::numeric
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.ref_nurture IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.reference_drivers(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT (hc.ref_drivers * 10)::numeric
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.ref_drivers IS NOT NULL;
$$;

-- ==================== PER-LAYER VERDICT FUNCTIONS ====================

-- Each returns nature / nurture / drivers cell values, composite, and layer verdict text.
-- Composite = weighted sum via hiregauge_layer_composite_weights for that layer.
-- Verdict text via _hiregauge_layer_verdict for consistency with existing per-layer thresholds.

CREATE OR REPLACE FUNCTION public.verdict_resume(p_candidate_id uuid)
RETURNS TABLE(nature numeric, nurture numeric, drivers numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_nat numeric; v_nur numeric; v_dr numeric;
  v_w_nat numeric; v_w_nur numeric; v_w_dr numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_nat := public.resume_nature(p_candidate_id);
  v_nur := public.resume_nurture(p_candidate_id);
  v_dr  := public.resume_drivers(p_candidate_id);

  SELECT max(CASE WHEN construct='nature'  THEN weight END),
         max(CASE WHEN construct='nurture' THEN weight END),
         max(CASE WHEN construct='drivers' THEN weight END)
  INTO v_w_nat, v_w_nur, v_w_dr
  FROM public.hiregauge_layer_composite_weights WHERE layer='resume';

  IF v_nat IS NOT NULL THEN v_sum := v_sum + v_nat * v_w_nat; v_wsum := v_wsum + v_w_nat; END IF;
  IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_w_nur; v_wsum := v_wsum + v_w_nur; END IF;
  IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_w_dr;  v_wsum := v_wsum + v_w_dr;  END IF;

  nature := v_nat; nurture := v_nur; drivers := v_dr;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('resume', composite);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.verdict_assessment(p_candidate_id uuid, p_role text DEFAULT NULL)
RETURNS TABLE(nature numeric, nurture numeric, drivers numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_nat numeric; v_nur numeric; v_dr numeric;
  v_w_nat numeric; v_w_nur numeric; v_w_dr numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_nat := public.assessment_nature(p_candidate_id, p_role);
  v_nur := public.assessment_nurture(p_candidate_id);
  v_dr  := public.assessment_drivers(p_candidate_id);

  SELECT max(CASE WHEN construct='nature'  THEN weight END),
         max(CASE WHEN construct='nurture' THEN weight END),
         max(CASE WHEN construct='drivers' THEN weight END)
  INTO v_w_nat, v_w_nur, v_w_dr
  FROM public.hiregauge_layer_composite_weights WHERE layer='assessment';

  IF v_nat IS NOT NULL THEN v_sum := v_sum + v_nat * v_w_nat; v_wsum := v_wsum + v_w_nat; END IF;
  IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_w_nur; v_wsum := v_wsum + v_w_nur; END IF;
  IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_w_dr;  v_wsum := v_wsum + v_w_dr;  END IF;

  nature := v_nat; nurture := v_nur; drivers := v_dr;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('assessment', composite);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.verdict_interview(p_candidate_id uuid)
RETURNS TABLE(nature numeric, nurture numeric, drivers numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_nat numeric; v_nur numeric; v_dr numeric;
  v_w_nat numeric; v_w_nur numeric; v_w_dr numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_nat := public.interview_nature(p_candidate_id);
  v_nur := public.interview_nurture(p_candidate_id);
  v_dr  := public.interview_drivers(p_candidate_id);

  SELECT max(CASE WHEN construct='nature'  THEN weight END),
         max(CASE WHEN construct='nurture' THEN weight END),
         max(CASE WHEN construct='drivers' THEN weight END)
  INTO v_w_nat, v_w_nur, v_w_dr
  FROM public.hiregauge_layer_composite_weights WHERE layer='interview';

  IF v_nat IS NOT NULL THEN v_sum := v_sum + v_nat * v_w_nat; v_wsum := v_wsum + v_w_nat; END IF;
  IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_w_nur; v_wsum := v_wsum + v_w_nur; END IF;
  IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_w_dr;  v_wsum := v_wsum + v_w_dr;  END IF;

  nature := v_nat; nurture := v_nur; drivers := v_dr;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('interview', composite);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.verdict_reference(p_candidate_id uuid)
RETURNS TABLE(nature numeric, nurture numeric, drivers numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_nat numeric; v_nur numeric; v_dr numeric;
  v_w_nat numeric; v_w_nur numeric; v_w_dr numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_nat := public.reference_nature(p_candidate_id);
  v_nur := public.reference_nurture(p_candidate_id);
  v_dr  := public.reference_drivers(p_candidate_id);

  SELECT max(CASE WHEN construct='nature'  THEN weight END),
         max(CASE WHEN construct='nurture' THEN weight END),
         max(CASE WHEN construct='drivers' THEN weight END)
  INTO v_w_nat, v_w_nur, v_w_dr
  FROM public.hiregauge_layer_composite_weights WHERE layer='reference';

  IF v_nat IS NOT NULL THEN v_sum := v_sum + v_nat * v_w_nat; v_wsum := v_wsum + v_w_nat; END IF;
  IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_w_nur; v_wsum := v_wsum + v_w_nur; END IF;
  IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_w_dr;  v_wsum := v_wsum + v_w_dr;  END IF;

  nature := v_nat; nurture := v_nur; drivers := v_dr;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('reference', composite);
  RETURN NEXT;
END;
$$;

-- ==================== OVERALL VERDICT ====================
-- Combines four layer verdicts into total verdict.
-- Character floor stripped as gate (per Peter 2026-07-23 + core_principle rewrite).
-- LSS autopass gate preserved (separate concern; catches invalid assessments).
-- Uses 3-construct rollup: nature_score / nurture_score / drivers_score computed as
-- weighted sums of the corresponding cell across all four layers, then overall = 35/30/35 blend.

CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL)
RETURNS TABLE(
  candidate_id uuid,
  verdict text,
  score_0_10 numeric,
  score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text,
  resume_score numeric,     resume_verdict text,
  assessment_score numeric, assessment_verdict text,
  interview_score numeric,  interview_verdict text,
  reference_score numeric,  reference_verdict text,
  nature_score numeric, nurture_score numeric, drivers_score numeric,
  dimensions_scored integer,
  confidence text,
  meta jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_ta                  record;
  v_r                   record;
  v_a                   record;
  v_i                   record;
  v_ref                 record;
  v_best                record;
  v_lss_autopass        jsonb;
  v_lss_status          text;
  v_dims                int := 0;

  -- Layer×construct within-construct weights (how much each layer contributes to a construct rollup)
  v_nat_r_w  numeric := 0.05; v_nat_a_w  numeric := 0.75; v_nat_i_w  numeric := 0.15; v_nat_ref_w  numeric := 0.05;
  v_nur_r_w  numeric := 0.10; v_nur_a_w  numeric := 0.15; v_nur_i_w  numeric := 0.45; v_nur_ref_w  numeric := 0.30;
  v_dr_r_w   numeric := 0.10; v_dr_a_w   numeric := 0.15; v_dr_i_w   numeric := 0.45; v_dr_ref_w   numeric := 0.30;

  -- Construct weights in final composite
  v_nat_w   numeric := 0.35; v_nur_w   numeric := 0.30; v_dr_w   numeric := 0.35;

  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_best FROM public.cts_best_fit_role(p_candidate_id);

  -- Dimensions_scored: match legacy counting exactly.
  -- Resume: 1 dim if any resume cell populated. Others: 1 dim per populated cell.
  IF v_r.nature IS NOT NULL OR v_r.nurture IS NOT NULL OR v_r.drivers IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.nature   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.nurture  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.drivers  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.nature   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.nurture  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.drivers  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.nature IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.nurture IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.drivers IS NOT NULL THEN v_dims := v_dims + 1; END IF;

  -- Construct rollups (weighted across layers within each construct)
  v_wsum := 0; v_sum := 0;
  IF v_r.nature   IS NOT NULL THEN v_sum := v_sum + v_r.nature   * v_nat_r_w;   v_wsum := v_wsum + v_nat_r_w;   END IF;
  IF v_a.nature   IS NOT NULL THEN v_sum := v_sum + v_a.nature   * v_nat_a_w;   v_wsum := v_wsum + v_nat_a_w;   END IF;
  IF v_i.nature   IS NOT NULL THEN v_sum := v_sum + v_i.nature   * v_nat_i_w;   v_wsum := v_wsum + v_nat_i_w;   END IF;
  IF v_ref.nature IS NOT NULL THEN v_sum := v_sum + v_ref.nature * v_nat_ref_w; v_wsum := v_wsum + v_nat_ref_w; END IF;
  nature_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.nurture   IS NOT NULL THEN v_sum := v_sum + v_r.nurture   * v_nur_r_w;   v_wsum := v_wsum + v_nur_r_w;   END IF;
  IF v_a.nurture   IS NOT NULL THEN v_sum := v_sum + v_a.nurture   * v_nur_a_w;   v_wsum := v_wsum + v_nur_a_w;   END IF;
  IF v_i.nurture   IS NOT NULL THEN v_sum := v_sum + v_i.nurture   * v_nur_i_w;   v_wsum := v_wsum + v_nur_i_w;   END IF;
  IF v_ref.nurture IS NOT NULL THEN v_sum := v_sum + v_ref.nurture * v_nur_ref_w; v_wsum := v_wsum + v_nur_ref_w; END IF;
  nurture_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.drivers   IS NOT NULL THEN v_sum := v_sum + v_r.drivers   * v_dr_r_w;   v_wsum := v_wsum + v_dr_r_w;   END IF;
  IF v_a.drivers   IS NOT NULL THEN v_sum := v_sum + v_a.drivers   * v_dr_a_w;   v_wsum := v_wsum + v_dr_a_w;   END IF;
  IF v_i.drivers   IS NOT NULL THEN v_sum := v_sum + v_i.drivers   * v_dr_i_w;   v_wsum := v_wsum + v_dr_i_w;   END IF;
  IF v_ref.drivers IS NOT NULL THEN v_sum := v_sum + v_ref.drivers * v_dr_ref_w; v_wsum := v_wsum + v_dr_ref_w; END IF;
  drivers_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  -- Composite = 35/30/35 across constructs
  v_wsum := 0; v_sum := 0;
  IF nature_score  IS NOT NULL THEN v_sum := v_sum + nature_score  * v_nat_w; v_wsum := v_wsum + v_nat_w; END IF;
  IF nurture_score IS NOT NULL THEN v_sum := v_sum + nurture_score * v_nur_w; v_wsum := v_wsum + v_nur_w; END IF;
  IF drivers_score IS NOT NULL THEN v_sum := v_sum + drivers_score * v_dr_w;  v_wsum := v_wsum + v_dr_w;  END IF;
  score_0_10 := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  -- Layer scores + verdicts (passthrough from per-layer functions)
  resume_score     := v_r.composite;    resume_verdict     := v_r.verdict;
  assessment_score := v_a.composite;    assessment_verdict := v_a.verdict;
  interview_score  := v_i.composite;    interview_verdict  := v_i.verdict;
  reference_score  := v_ref.composite;  reference_verdict  := v_ref.verdict;

  -- LSS autopass check (preserved; not a character floor gate)
  v_lss_autopass := public._hiregauge_lss_autopass(
    v_ta.lss_total_accuracy, v_ta.reliability, v_ta.analytical::numeric,
    v_ta.assessment_target_role, v_best.best_role,
    v_ta.res_licenses, v_ta.res_education, v_ta.res_prior_similar_role
  );
  v_lss_status := v_lss_autopass->>'status';

  -- Final verdict: no character floor gate. Just score-based + LSS autopass.
  verdict := CASE
    WHEN score_0_10 IS NULL THEN 'insufficient_data'
    WHEN v_lss_status = 'decline_lss' THEN 'decline_lss'
    ELSE (CASE public._hiregauge_layer_verdict('framework', score_0_10)
            WHEN 'pass' THEN 'hire'
            WHEN 'consider' THEN 'consider'
            ELSE 'decline'
          END)
  END;

  score_hire_at_70 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 70 THEN 'hire' WHEN score_0_10 >= 55 THEN 'consider' ELSE 'decline' END;
  score_hire_at_75 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 75 THEN 'hire' WHEN score_0_10 >= 60 THEN 'consider' ELSE 'decline' END;
  score_hire_at_80 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 80 THEN 'hire' WHEN score_0_10 >= 65 THEN 'consider' ELSE 'decline' END;

  candidate_id := p_candidate_id;
  dimensions_scored := v_dims;
  confidence := CASE WHEN v_dims >= 9 THEN 'high' WHEN v_dims >= 5 THEN 'medium' ELSE 'low' END;

  meta := jsonb_build_object(
    'matrix', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_r.nature,  'assessment', v_a.nature,  'interview', v_i.nature,  'reference', v_ref.nature),
      'nurture', jsonb_build_object('resume', v_r.nurture, 'assessment', v_a.nurture, 'interview', v_i.nurture, 'reference', v_ref.nurture),
      'drivers', jsonb_build_object('resume', v_r.drivers, 'assessment', v_a.drivers, 'interview', v_i.drivers, 'reference', v_ref.drivers)),
    'role_used_for_assessment_nature', COALESCE(p_role, v_ta.assessment_target_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_os',   v_best.best_os,
    'lss_autopass',  v_lss_autopass);

  RETURN NEXT;
END;
$$;
