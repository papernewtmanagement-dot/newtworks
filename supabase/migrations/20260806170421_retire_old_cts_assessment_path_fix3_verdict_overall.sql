-- Fix: verdict_overall unconditionally read v_ta.lss_total_accuracy and
-- v_ta.analytical (both just-dropped old-only columns) to feed
-- _hiregauge_lss_autopass, an exception gate calibrated to the old 0-35 raw
-- LSS scale. New-instrument candidates never populated these columns anyway,
-- so _hiregauge_lss_autopass already always returned 'not_scored' for them --
-- behavior is unchanged, just passing NULL literals now instead of columns
-- that no longer exist. NOTE: this gate has no new-instrument (GMA-based)
-- equivalent built yet -- flagging as a follow-up decision for Peter, not
-- inventing a mapping here.
CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, capability_score numeric, character_score numeric, commitment_score numeric, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record;
  v_lss_autopass jsonb; v_lss_status text; v_dims int := 0;
  v_cap_r_w numeric := 0.05; v_cap_a_w numeric := 0.75; v_cap_i_w numeric := 0.15; v_cap_ref_w numeric := 0.05;
  v_chr_r_w numeric := 0.10; v_chr_a_w numeric := 0.15; v_chr_i_w numeric := 0.45; v_chr_ref_w numeric := 0.30;
  v_com_r_w numeric := 0.10; v_com_a_w numeric := 0.15; v_com_i_w numeric := 0.45; v_com_ref_w numeric := 0.30;
  v_cap_w numeric := 1.0/3; v_chr_w numeric := 1.0/3; v_com_w numeric := 1.0/3;
  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_best FROM public.assessment_best_fit_role(p_candidate_id);

  IF v_r.capability_score IS NOT NULL OR v_r.character_score IS NOT NULL OR v_r.commitment_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.capability_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.character_score    IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.commitment_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.capability_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.character_score    IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.commitment_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.capability_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.character_score  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.commitment_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;

  v_wsum := 0; v_sum := 0;
  IF v_r.capability_score   IS NOT NULL THEN v_sum := v_sum + v_r.capability_score   * v_cap_r_w;   v_wsum := v_wsum + v_cap_r_w;   END IF;
  IF v_a.capability_score   IS NOT NULL THEN v_sum := v_sum + v_a.capability_score   * v_cap_a_w;   v_wsum := v_wsum + v_cap_a_w;   END IF;
  IF v_i.capability_score   IS NOT NULL THEN v_sum := v_sum + v_i.capability_score   * v_cap_i_w;   v_wsum := v_wsum + v_cap_i_w;   END IF;
  IF v_ref.capability_score IS NOT NULL THEN v_sum := v_sum + v_ref.capability_score * v_cap_ref_w; v_wsum := v_wsum + v_cap_ref_w; END IF;
  capability_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.character_score   IS NOT NULL THEN v_sum := v_sum + v_r.character_score   * v_chr_r_w;   v_wsum := v_wsum + v_chr_r_w;   END IF;
  IF v_a.character_score   IS NOT NULL THEN v_sum := v_sum + v_a.character_score   * v_chr_a_w;   v_wsum := v_wsum + v_chr_a_w;   END IF;
  IF v_i.character_score   IS NOT NULL THEN v_sum := v_sum + v_i.character_score   * v_chr_i_w;   v_wsum := v_wsum + v_chr_i_w;   END IF;
  IF v_ref.character_score IS NOT NULL THEN v_sum := v_sum + v_ref.character_score * v_chr_ref_w; v_wsum := v_wsum + v_chr_ref_w; END IF;
  character_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_r.commitment_score   * v_com_r_w;   v_wsum := v_wsum + v_com_r_w;   END IF;
  IF v_a.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_a.commitment_score   * v_com_a_w;   v_wsum := v_wsum + v_com_a_w;   END IF;
  IF v_i.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_i.commitment_score   * v_com_i_w;   v_wsum := v_wsum + v_com_i_w;   END IF;
  IF v_ref.commitment_score IS NOT NULL THEN v_sum := v_sum + v_ref.commitment_score * v_com_ref_w; v_wsum := v_wsum + v_com_ref_w; END IF;
  commitment_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF capability_score IS NOT NULL THEN v_sum := v_sum + capability_score * v_cap_w; v_wsum := v_wsum + v_cap_w; END IF;
  IF character_score  IS NOT NULL THEN v_sum := v_sum + character_score  * v_chr_w; v_wsum := v_wsum + v_chr_w; END IF;
  IF commitment_score IS NOT NULL THEN v_sum := v_sum + commitment_score * v_com_w; v_wsum := v_wsum + v_com_w; END IF;
  score_0_10 := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  resume_score     := v_r.composite;    resume_verdict     := v_r.verdict;
  assessment_score := v_a.composite;    assessment_verdict := v_a.verdict;
  interview_score  := v_i.composite;    interview_verdict  := v_i.verdict;
  reference_score  := v_ref.composite;  reference_verdict  := v_ref.verdict;

  -- lss_total_accuracy / analytical (old-only, dropped 2026-08-06): this
  -- exception gate is calibrated to the old 0-35 raw LSS scale and has no
  -- new-instrument (GMA) equivalent yet. New-instrument candidates never had
  -- these populated, so this always returned 'not_scored' for them already --
  -- passing NULL preserves that behavior exactly, no new mapping invented.
  v_lss_autopass := public._hiregauge_lss_autopass(
    NULL::numeric, v_ta.reliability, NULL::numeric,
    v_best.best_role,
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
      'capability', jsonb_build_object('resume', v_r.capability_score, 'assessment', v_a.capability_score, 'interview', v_i.capability_score, 'reference', v_ref.capability_score),
      'character',  jsonb_build_object('resume', v_r.character_score,  'assessment', v_a.character_score,  'interview', v_i.character_score,  'reference', v_ref.character_score),
      'commitment', jsonb_build_object('resume', v_r.commitment_score, 'assessment', v_a.commitment_score, 'interview', v_i.commitment_score, 'reference', v_ref.commitment_score)),
    'construct_weights', jsonb_build_object(
      'capability', v_cap_w,
      'character',  v_chr_w,
      'commitment', v_com_w),
    'construct_weight_basis', 'equal weights (1/3 each) -- robust absent a large local validation sample (Wainer 1976); moved off 35/30/35 2026-08-05, no data ever supported weighting Character below the other two',
    'layer_weights_within_construct', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_cap_r_w, 'assessment', v_cap_a_w, 'interview', v_cap_i_w, 'reference', v_cap_ref_w),
      'character',  jsonb_build_object('resume', v_chr_r_w, 'assessment', v_chr_a_w, 'interview', v_chr_i_w, 'reference', v_chr_ref_w),
      'commitment', jsonb_build_object('resume', v_com_r_w, 'assessment', v_com_a_w, 'interview', v_com_i_w, 'reference', v_com_ref_w)),
    'role_used_for_assessment_capability', COALESCE(p_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_score', v_best.best_fit_score,
    'lss_autopass',  v_lss_autopass);
  RETURN NEXT;
END;
$function$;
