-- verdict_overall — additive: emit construct_weights + layer_weights_within_construct in meta jsonb.
-- Frontend CandidateDetail.jsx four-layer matrix reads meta.construct_weights and
-- meta.layer_weights_within_construct for the column-header % and per-cell "weight XX%" label.
-- Prior RPC computed the weights as locals but never surfaced them, so the collapsed matrix cells
-- rendered "weight " with no number (pctFmt(null) -> ""). This restores the intended display.
-- Pure add to meta shape. No consumers break.

CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, nature_score numeric, nurture_score numeric, drivers_score numeric, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record;
  v_lss_autopass jsonb; v_lss_status text; v_dims int := 0;
  v_nat_r_w numeric := 0.05; v_nat_a_w numeric := 0.75; v_nat_i_w numeric := 0.15; v_nat_ref_w numeric := 0.05;
  v_nur_r_w numeric := 0.10; v_nur_a_w numeric := 0.15; v_nur_i_w numeric := 0.45; v_nur_ref_w numeric := 0.30;
  v_dr_r_w  numeric := 0.10; v_dr_a_w  numeric := 0.15; v_dr_i_w  numeric := 0.45; v_dr_ref_w  numeric := 0.30;
  v_nat_w numeric := 0.35; v_nur_w numeric := 0.30; v_dr_w numeric := 0.35;
  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_best FROM public.cts_best_fit_role(p_candidate_id);
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
  v_wsum := 0; v_sum := 0;
  IF nature_score  IS NOT NULL THEN v_sum := v_sum + nature_score  * v_nat_w; v_wsum := v_wsum + v_nat_w; END IF;
  IF nurture_score IS NOT NULL THEN v_sum := v_sum + nurture_score * v_nur_w; v_wsum := v_wsum + v_nur_w; END IF;
  IF drivers_score IS NOT NULL THEN v_sum := v_sum + drivers_score * v_dr_w;  v_wsum := v_wsum + v_dr_w;  END IF;
  score_0_10 := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  resume_score     := v_r.composite;    resume_verdict     := v_r.verdict;
  assessment_score := v_a.composite;    assessment_verdict := v_a.verdict;
  interview_score  := v_i.composite;    interview_verdict  := v_i.verdict;
  reference_score  := v_ref.composite;  reference_verdict  := v_ref.verdict;
  v_lss_autopass := public._hiregauge_lss_autopass(
    v_ta.lss_total_accuracy, v_ta.reliability, v_ta.analytical::numeric,
    v_ta.assessment_target_role, v_best.best_role,
    v_ta.resume_analysis->'qualifications'->'licenses',
    v_ta.resume_analysis->'qualifications'->'education',
    v_ta.resume_analysis->'qualifications'->'prior_similar_role'
  );
  v_lss_status := v_lss_autopass->>'status';
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
    'construct_weights', jsonb_build_object(
      'nature',  v_nat_w,
      'nurture', v_nur_w,
      'drivers', v_dr_w),
    'layer_weights_within_construct', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_nat_r_w, 'assessment', v_nat_a_w, 'interview', v_nat_i_w, 'reference', v_nat_ref_w),
      'nurture', jsonb_build_object('resume', v_nur_r_w, 'assessment', v_nur_a_w, 'interview', v_nur_i_w, 'reference', v_nur_ref_w),
      'drivers', jsonb_build_object('resume', v_dr_r_w,  'assessment', v_dr_a_w,  'interview', v_dr_i_w,  'reference', v_dr_ref_w)),
    'role_used_for_assessment_nature', COALESCE(p_role, v_ta.assessment_target_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_os',   v_best.best_os,
    'lss_autopass',  v_lss_autopass);
  RETURN NEXT;
END;
$function$
;
