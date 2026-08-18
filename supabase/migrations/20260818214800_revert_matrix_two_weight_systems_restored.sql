-- 2026-08-18 — REVERT of the two same-day migrations (20260818211350, 20260818211652).
-- Peter: the matrix has TWO deliberate weight systems. The vertical (within-construct)
-- weights hard-coded in verdict_overall show how the constructs total up; the second
-- weighting (hiregauge_layer_composite_weights) is used to calculate each LAYER's total.
-- They were never meant to be collapsed into one matrix. Restoring both exactly.
-- Kept from the same-day work (no behavior change): v_hiring_candidates sources its iv_*
-- columns from one verdict_interview() lateral instead of duplicated inline arithmetic.

-- 1) Drop the per-construct-sum guard (it enforces the collapsed design, not this one).
DROP TRIGGER IF EXISTS trg_hlcw_construct_sums ON public.hiregauge_layer_composite_weights;
DROP FUNCTION IF EXISTS public._hlcw_check_construct_sums();

-- 2) Restore the layer (row) weights exactly as they were.
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.2000, updated_at = now() WHERE layer='resume'     AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4000, updated_at = now() WHERE layer='resume'     AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4000, updated_at = now() WHERE layer='resume'     AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.7143, updated_at = now() WHERE layer='assessment' AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1429, updated_at = now() WHERE layer='assessment' AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1429, updated_at = now() WHERE layer='assessment' AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1429, updated_at = now() WHERE layer='interview'  AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4286, updated_at = now() WHERE layer='interview'  AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4286, updated_at = now() WHERE layer='interview'  AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.0909, updated_at = now() WHERE layer='reference'  AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.5455, updated_at = now() WHERE layer='reference'  AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.3636, updated_at = now() WHERE layer='reference'  AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.5000, updated_at = now() WHERE layer='screen'     AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.5000, updated_at = now() WHERE layer='screen'     AND construct='commitment';
DELETE FROM public.hiregauge_layer_composite_weights WHERE layer='screen' AND construct='capability';

COMMENT ON TABLE public.hiregauge_layer_composite_weights IS
  'LAYER (row) weights: how each layer''s Total is calculated from its three construct cells; each layer''s weights sum to 1.0. Read by verdict_resume/assessment/interview/reference/screen. This is a DELIBERATELY SEPARATE weighting from the vertical within-construct weights hard-coded in verdict_overall (which show how the constructs total up to the overall). Peter 2026-08-18: two systems by design — do not collapse, do not derive one from the other. Construct rename trap (PK + CHECK on literal construct names) still applies.';

-- 3) Restore verdict_resume (layer total = construct cells blended by this table's resume row).
CREATE OR REPLACE FUNCTION public.verdict_resume(p_candidate_id uuid)
 RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_cap := public.resume_capability(p_candidate_id);
  v_chr := public.resume_character(p_candidate_id);
  v_com := public.resume_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='resume';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('resume', composite);
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.verdict_resume(uuid) IS NULL;

-- 4) Restore verdict_overall with its own hard-coded vertical (within-construct) weights.
CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, capability_score numeric, character_score numeric, commitment_score numeric, dimensions_scored integer, confidence text, meta jsonb, screen_score numeric, screen_verdict text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record; v_s record;
  v_dims int := 0;
  v_cap_r_w numeric := 0.05; v_cap_a_w numeric := 0.75; v_cap_i_w numeric := 0.15; v_cap_ref_w numeric := 0.05;
  v_chr_r_w numeric := 0.10; v_chr_a_w numeric := 0.15; v_chr_i_w numeric := 0.40; v_chr_ref_w numeric := 0.30; v_chr_s_w numeric := 0.05;
  v_com_r_w numeric := 0.10; v_com_a_w numeric := 0.15; v_com_i_w numeric := 0.40; v_com_ref_w numeric := 0.25; v_com_s_w numeric := 0.10;
  v_cap_w numeric := 1.0/3; v_chr_w numeric := 1.0/3; v_com_w numeric := 1.0/3;
  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_s    FROM public.verdict_screen(p_candidate_id);
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
  IF v_s.character_score    IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_s.commitment_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;

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
  IF v_s.character_score   IS NOT NULL THEN v_sum := v_sum + v_s.character_score   * v_chr_s_w;   v_wsum := v_wsum + v_chr_s_w;   END IF;
  character_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_r.commitment_score   * v_com_r_w;   v_wsum := v_wsum + v_com_r_w;   END IF;
  IF v_a.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_a.commitment_score   * v_com_a_w;   v_wsum := v_wsum + v_com_a_w;   END IF;
  IF v_i.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_i.commitment_score   * v_com_i_w;   v_wsum := v_wsum + v_com_i_w;   END IF;
  IF v_ref.commitment_score IS NOT NULL THEN v_sum := v_sum + v_ref.commitment_score * v_com_ref_w; v_wsum := v_wsum + v_com_ref_w; END IF;
  IF v_s.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_s.commitment_score   * v_com_s_w;   v_wsum := v_wsum + v_com_s_w;   END IF;
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
  screen_score      := v_s.composite;   screen_verdict      := v_s.verdict;

  verdict := CASE
    WHEN score_0_10 IS NULL THEN 'insufficient_data'
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
  confidence := CASE WHEN v_dims >= 11 THEN 'high' WHEN v_dims >= 6 THEN 'medium' ELSE 'low' END;
  meta := jsonb_build_object(
    'matrix', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_r.capability_score, 'assessment', v_a.capability_score, 'interview', v_i.capability_score, 'reference', v_ref.capability_score, 'screen', v_s.capability_score),
      'character',  jsonb_build_object('resume', v_r.character_score,  'assessment', v_a.character_score,  'interview', v_i.character_score,  'reference', v_ref.character_score,  'screen', v_s.character_score),
      'commitment', jsonb_build_object('resume', v_r.commitment_score, 'assessment', v_a.commitment_score, 'interview', v_i.commitment_score, 'reference', v_ref.commitment_score, 'screen', v_s.commitment_score)),
    'construct_weights', jsonb_build_object(
      'capability', v_cap_w,
      'character',  v_chr_w,
      'commitment', v_com_w),
    'construct_weight_basis', 'equal weights (1/3 each) -- robust absent a large local validation sample (Wainer 1976); moved off 35/30/35 2026-08-05, no data ever supported weighting Character below the other two. Screen layer added 2026-08-13 at chr .05 / com .10 / cap 0 -- see hiregauge_rules screen_layer_config for basis.',
    'layer_weights_within_construct', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_cap_r_w, 'assessment', v_cap_a_w, 'interview', v_cap_i_w, 'reference', v_cap_ref_w, 'screen', 0),
      'character',  jsonb_build_object('resume', v_chr_r_w, 'assessment', v_chr_a_w, 'interview', v_chr_i_w, 'reference', v_chr_ref_w, 'screen', v_chr_s_w),
      'commitment', jsonb_build_object('resume', v_com_r_w, 'assessment', v_com_a_w, 'interview', v_com_i_w, 'reference', v_com_ref_w, 'screen', v_com_s_w)),
    'role_used_for_assessment_capability', COALESCE(p_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_score', v_best.best_fit_score);
  RETURN NEXT;
END;
$function$;
