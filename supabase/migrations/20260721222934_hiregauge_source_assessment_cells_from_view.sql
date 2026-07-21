-- Follow-up to 20260721214516_rescale_three_construct_verdict_to_100_and_wire_iv.
--
-- Architectural fix: source assessment cells (v_na, v_nua, v_da) from the
-- v_hiring_candidates view rather than recomputing them internally. This locks
-- the RPC's assessment_score to view.assessment_composite so the Matrix
-- Assessment ROW cells (which the frontend already reads from view.assessment_*
-- per step 4 of the interview layer rewire) always match the layer Total column.
--
-- Prior behavior (mine, 20260721214516):
--   v_na  := 10 * ((OS/10)*0.55 + (comp/10)*0.35 + lss_score*0.10)   -- blended
--   v_nua := 70/50/20/40 based on reliability x distortion            -- RPC formula
--   v_da  := 10 * cts_drivers_assessment_cell(id, best_fit_role)      -- role-specific
--
-- New behavior:
--   v_na  := view.assessment_nature  (OS for assessment_target_role; falls back
--            to best_fit_role's OS when target_role is null)
--   v_nua := view.assessment_nurture (honesty from distortion, concern from
--            compassion+belief, work_ethic from reliability — averaged)
--   v_da  := view.assessment_drivers ((deadline + recognition + independent)/3)
--
-- For _by_role, each role loop uses that role's own OS as v_na. v_nua and v_da
-- are role-invariant (single value from view).
--
-- Priscilla verification target (assessment_target_role='aspirant', OS=62):
--   nature=61.44, nurture=60.85, drivers=49.64, score_0_10=57.13, verdict=decline
--   assessment_score=64.26 (matches view.assessment_composite exactly)
--
-- Divergence handling for candidates with assessment_target_role IS NULL:
--   35 of 60 hiring_candidates rows have target_role null. For those, view's
--   assessment_nature is NULL. Fallback: use cts_best_fit_role's best_os so
--   candidates without an explicit target still get a valid nature cell.

CREATE OR REPLACE FUNCTION public.hiregauge_three_construct_verdict(p_assessment_id uuid)
 RETURNS TABLE(assessment_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, nature_score numeric, nurture_score numeric, drivers_score numeric, character_floor_status text, character_floor_failed text[], retrospective_verdict text, retrospective_notes text, retrospective_context text, calibration_status text, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record;
  v_team_id uuid;
  v_is_active boolean;
  v_is_archived boolean;

  v_nr numeric; v_na numeric; v_ni numeric; v_nref numeric;
  v_nur numeric; v_nua numeric; v_nui numeric; v_nuref numeric;
  v_dr numeric; v_da numeric; v_di numeric; v_dref numeric;

  v_nature_r_w   numeric := 0.05; v_nature_a_w   numeric := 0.75; v_nature_i_w   numeric := 0.15; v_nature_ref_w   numeric := 0.05;
  v_nurture_r_w  numeric := 0.10; v_nurture_a_w  numeric := 0.15; v_nurture_i_w  numeric := 0.45; v_nurture_ref_w  numeric := 0.30;
  v_drivers_r_w  numeric := 0.10; v_drivers_a_w  numeric := 0.15; v_drivers_i_w  numeric := 0.45; v_drivers_ref_w  numeric := 0.30;

  v_nature_w numeric := 0.35; v_nurture_w numeric := 0.30; v_drivers_w numeric := 0.35;

  v_row_r_nat   numeric; v_row_r_nur   numeric; v_row_r_dr   numeric;
  v_row_a_nat   numeric; v_row_a_nur   numeric; v_row_a_dr   numeric;
  v_row_i_nat   numeric; v_row_i_nur   numeric; v_row_i_dr   numeric;
  v_row_ref_nat numeric; v_row_ref_nur numeric; v_row_ref_dr numeric;

  v_best_fit_role text;
  v_best_fit_os numeric;
  v_best_role_category text;
  v_display_label text;
  v_lss_acc numeric;

  v_dims_scored int := 0;
  v_char_floors_failed text[] := ARRAY[]::text[];
  v_char_floor_status text;
  v_verdict text;
  v_confidence text;
  v_calibration text;
  v_retro_verdict text;
BEGIN
  SELECT * INTO v_ta FROM public.v_hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT
    MAX(CASE WHEN layer='resume'     AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='resume'     AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='resume'     AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='drivers' THEN weight END)
  INTO
    v_row_r_nat, v_row_r_nur, v_row_r_dr,
    v_row_a_nat, v_row_a_nur, v_row_a_dr,
    v_row_i_nat, v_row_i_nur, v_row_i_dr,
    v_row_ref_nat, v_row_ref_nur, v_row_ref_dr
  FROM public.hiregauge_layer_composite_weights;

  SELECT t.id, (t.archived_at IS NULL AND COALESCE(t.is_active, false)), (t.archived_at IS NOT NULL)
    INTO v_team_id, v_is_active, v_is_archived
    FROM public.team t WHERE t.id = v_ta.team_member_id;

  retrospective_context := CASE
    WHEN v_is_active THEN 'hired_and_performing'
    WHEN v_is_archived THEN 'former_team'
    ELSE NULL
  END;

  IF v_ta.res_nature IS NOT NULL THEN v_nr := v_ta.res_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.res_nurture IS NOT NULL THEN v_nur := v_ta.res_nurture::numeric; END IF;
  IF v_ta.res_drivers IS NOT NULL THEN v_dr := v_ta.res_drivers::numeric; END IF;
  IF v_nr IS NULL AND v_ta.resume_quality IS NOT NULL THEN
    v_nr := 10 * v_ta.resume_quality::numeric;
    v_nur := 10 * v_ta.resume_quality::numeric;
    v_dr := 10 * v_ta.resume_quality::numeric;
    v_dims_scored := v_dims_scored + 1;
  END IF;

  -- Assessment cells sourced from view (single source of truth). Frontend Matrix
  -- Assessment ROW reads view.assessment_* directly (step 4), so this keeps the
  -- RPC's assessment_score locked to view.assessment_composite.
  -- Nature fallback: if assessment_target_role IS NULL, use best_fit_role's OS.
  IF v_ta.assessment_nature IS NOT NULL THEN
    v_na := v_ta.assessment_nature::numeric;
  ELSIF v_ta.deadline_motivation IS NOT NULL THEN
    SELECT bfr.best_role, bfr.best_role_category, bfr.display_label, bfr.best_os::numeric
      INTO v_best_fit_role, v_best_role_category, v_display_label, v_best_fit_os
      FROM public.cts_best_fit_role(p_assessment_id) bfr;
    v_na := v_best_fit_os;
  END IF;
  IF v_na IS NOT NULL THEN v_dims_scored := v_dims_scored + 1; END IF;

  IF v_ta.assessment_nurture IS NOT NULL THEN
    v_nua := v_ta.assessment_nurture::numeric;
    v_dims_scored := v_dims_scored + 1;
  END IF;

  IF v_ta.assessment_drivers IS NOT NULL THEN
    v_da := v_ta.assessment_drivers::numeric;
    v_dims_scored := v_dims_scored + 1;
  END IF;

  -- Ensure best_fit metadata is available for the meta payload even when we didn't
  -- have to fall back to it for v_na.
  IF v_best_fit_role IS NULL AND v_ta.deadline_motivation IS NOT NULL THEN
    SELECT bfr.best_role, bfr.best_role_category, bfr.display_label, bfr.best_os::numeric
      INTO v_best_fit_role, v_best_role_category, v_display_label, v_best_fit_os
      FROM public.cts_best_fit_role(p_assessment_id) bfr;
  END IF;

  v_lss_acc := COALESCE(v_ta.lss_total_accuracy, 0);

  IF v_ta.iv_nature IS NOT NULL THEN v_ni := v_ta.iv_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.iv_nurture IS NOT NULL THEN v_nui := v_ta.iv_nurture::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.iv_drivers IS NOT NULL THEN v_di := v_ta.iv_drivers::numeric; v_dims_scored := v_dims_scored + 1; END IF;

  IF v_ta.char_honesty IS NOT NULL AND v_ta.char_honesty < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_honesty'); END IF;
  IF v_ta.char_hwe     IS NOT NULL AND v_ta.char_hwe     < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_hwe'); END IF;
  IF v_ta.char_persres IS NOT NULL AND v_ta.char_persres < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_persres'); END IF;
  IF v_ta.char_concern IS NOT NULL AND v_ta.char_concern < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_concern'); END IF;

  character_floor_status := CASE
    WHEN array_length(v_char_floors_failed, 1) > 0 THEN 'floor_failed'
    WHEN v_ta.char_honesty IS NOT NULL OR v_ta.char_hwe IS NOT NULL OR v_ta.char_persres IS NOT NULL OR v_ta.char_concern IS NOT NULL THEN 'floor_passed'
    ELSE 'not_scored'
  END;

  IF v_ta.ref_nature IS NOT NULL THEN v_nref := 10 * v_ta.ref_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.ref_nurture IS NOT NULL THEN v_nuref := 10 * v_ta.ref_nurture::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.ref_drivers IS NOT NULL THEN v_dref := 10 * v_ta.ref_drivers::numeric; v_dims_scored := v_dims_scored + 1; END IF;

  DECLARE v_wsum numeric; v_sum numeric;
  BEGIN
    v_wsum := 0; v_sum := 0;
    IF v_nr   IS NOT NULL THEN v_sum := v_sum + v_nr   * v_nature_r_w;   v_wsum := v_wsum + v_nature_r_w;   END IF;
    IF v_na   IS NOT NULL THEN v_sum := v_sum + v_na   * v_nature_a_w;   v_wsum := v_wsum + v_nature_a_w;   END IF;
    IF v_ni   IS NOT NULL THEN v_sum := v_sum + v_ni   * v_nature_i_w;   v_wsum := v_wsum + v_nature_i_w;   END IF;
    IF v_nref IS NOT NULL THEN v_sum := v_sum + v_nref * v_nature_ref_w; v_wsum := v_wsum + v_nature_ref_w; END IF;
    nature_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nur   IS NOT NULL THEN v_sum := v_sum + v_nur   * v_nurture_r_w;   v_wsum := v_wsum + v_nurture_r_w;   END IF;
    IF v_nua   IS NOT NULL THEN v_sum := v_sum + v_nua   * v_nurture_a_w;   v_wsum := v_wsum + v_nurture_a_w;   END IF;
    IF v_nui   IS NOT NULL THEN v_sum := v_sum + v_nui   * v_nurture_i_w;   v_wsum := v_wsum + v_nurture_i_w;   END IF;
    IF v_nuref IS NOT NULL THEN v_sum := v_sum + v_nuref * v_nurture_ref_w; v_wsum := v_wsum + v_nurture_ref_w; END IF;
    nurture_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_dr   IS NOT NULL THEN v_sum := v_sum + v_dr   * v_drivers_r_w;   v_wsum := v_wsum + v_drivers_r_w;   END IF;
    IF v_da   IS NOT NULL THEN v_sum := v_sum + v_da   * v_drivers_a_w;   v_wsum := v_wsum + v_drivers_a_w;   END IF;
    IF v_di   IS NOT NULL THEN v_sum := v_sum + v_di   * v_drivers_i_w;   v_wsum := v_wsum + v_drivers_i_w;   END IF;
    IF v_dref IS NOT NULL THEN v_sum := v_sum + v_dref * v_drivers_ref_w; v_wsum := v_wsum + v_drivers_ref_w; END IF;
    drivers_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;
  END;

  DECLARE v_wsum numeric; v_sum numeric;
  BEGIN
    v_wsum := 0; v_sum := 0;
    IF v_nr  IS NOT NULL THEN v_sum := v_sum + v_nr  * v_row_r_nat; v_wsum := v_wsum + v_row_r_nat; END IF;
    IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_row_r_nur; v_wsum := v_wsum + v_row_r_nur; END IF;
    IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_row_r_dr;  v_wsum := v_wsum + v_row_r_dr;  END IF;
    resume_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_na  IS NOT NULL THEN v_sum := v_sum + v_na  * v_row_a_nat; v_wsum := v_wsum + v_row_a_nat; END IF;
    IF v_nua IS NOT NULL THEN v_sum := v_sum + v_nua * v_row_a_nur; v_wsum := v_wsum + v_row_a_nur; END IF;
    IF v_da  IS NOT NULL THEN v_sum := v_sum + v_da  * v_row_a_dr;  v_wsum := v_wsum + v_row_a_dr;  END IF;
    assessment_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_ni  IS NOT NULL THEN v_sum := v_sum + v_ni  * v_row_i_nat; v_wsum := v_wsum + v_row_i_nat; END IF;
    IF v_nui IS NOT NULL THEN v_sum := v_sum + v_nui * v_row_i_nur; v_wsum := v_wsum + v_row_i_nur; END IF;
    IF v_di  IS NOT NULL THEN v_sum := v_sum + v_di  * v_row_i_dr;  v_wsum := v_wsum + v_row_i_dr;  END IF;
    interview_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nref  IS NOT NULL THEN v_sum := v_sum + v_nref  * v_row_ref_nat; v_wsum := v_wsum + v_row_ref_nat; END IF;
    IF v_nuref IS NOT NULL THEN v_sum := v_sum + v_nuref * v_row_ref_nur; v_wsum := v_wsum + v_row_ref_nur; END IF;
    IF v_dref  IS NOT NULL THEN v_sum := v_sum + v_dref  * v_row_ref_dr;  v_wsum := v_wsum + v_row_ref_dr;  END IF;
    reference_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;
  END;

  DECLARE v_wsum numeric := 0; v_sum numeric := 0;
  BEGIN
    IF nature_score IS NOT NULL THEN v_sum := v_sum + nature_score * v_nature_w; v_wsum := v_wsum + v_nature_w; END IF;
    IF nurture_score IS NOT NULL THEN v_sum := v_sum + nurture_score * v_nurture_w; v_wsum := v_wsum + v_nurture_w; END IF;
    IF drivers_score IS NOT NULL THEN v_sum := v_sum + drivers_score * v_drivers_w; v_wsum := v_wsum + v_drivers_w; END IF;
    score_0_10 := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;
  END;

  resume_verdict := CASE
    WHEN resume_score IS NULL THEN 'not_scored'
    WHEN resume_score >= 70 THEN 'pass'
    WHEN resume_score >= 50 THEN 'consider'
    ELSE 'decline'
  END;
  assessment_verdict := CASE
    WHEN assessment_score IS NULL THEN 'not_scored'
    WHEN assessment_score >= 75 THEN 'pass'
    WHEN assessment_score >= 60 THEN 'consider'
    ELSE 'decline'
  END;
  interview_verdict := CASE
    WHEN interview_score IS NULL THEN 'not_scored'
    WHEN character_floor_status = 'floor_failed' THEN 'decline_character'
    WHEN interview_score >= 75 THEN 'pass'
    WHEN interview_score >= 60 THEN 'consider'
    ELSE 'decline'
  END;
  reference_verdict := CASE
    WHEN reference_score IS NULL THEN 'not_scored'
    WHEN reference_score >= 75 THEN 'pass'
    WHEN reference_score >= 60 THEN 'consider'
    ELSE 'decline'
  END;

  verdict := CASE
    WHEN character_floor_status = 'floor_failed' THEN 'decline_character'
    WHEN score_0_10 IS NULL THEN 'insufficient_data'
    WHEN score_0_10 >= 75 THEN 'hire'
    WHEN score_0_10 >= 60 THEN 'consider'
    ELSE 'decline'
  END;

  score_hire_at_70 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 70 THEN 'hire' WHEN score_0_10 >= 55 THEN 'consider' ELSE 'decline' END;
  score_hire_at_75 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 75 THEN 'hire' WHEN score_0_10 >= 60 THEN 'consider' ELSE 'decline' END;
  score_hire_at_80 := CASE WHEN score_0_10 IS NULL THEN 'n/a'
    WHEN score_0_10 >= 80 THEN 'hire' WHEN score_0_10 >= 65 THEN 'consider' ELSE 'decline' END;

  v_retro_verdict := COALESCE(v_ta.retrospective_verdict_override, 'not_scored');
  retrospective_verdict := v_retro_verdict;
  retrospective_notes := v_ta.retrospective_notes;

  v_calibration := CASE
    WHEN v_retro_verdict = 'not_scored' THEN 'no_retrospective'
    WHEN v_retro_verdict = 'pass' AND verdict IN ('hire','consider') THEN 'framework_agrees_positive'
    WHEN v_retro_verdict = 'fail_confirmed' AND verdict IN ('decline','decline_character') THEN 'framework_agrees_negative'
    WHEN v_retro_verdict = 'pass' AND verdict IN ('decline','decline_character') THEN 'framework_missed_positive'
    WHEN v_retro_verdict = 'fail_confirmed' AND verdict IN ('hire','consider') THEN 'framework_missed_negative'
    WHEN v_retro_verdict = 'flag' THEN 'partial'
    ELSE 'no_retrospective'
  END;
  calibration_status := v_calibration;

  character_floor_failed := v_char_floors_failed;
  dimensions_scored := v_dims_scored;
  v_confidence := CASE WHEN v_dims_scored >= 9 THEN 'high' WHEN v_dims_scored >= 5 THEN 'medium' ELSE 'low' END;
  confidence := v_confidence;

  assessment_id := p_assessment_id;
  meta := jsonb_build_object(
    'matrix', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_nr,  'assessment', v_na,  'interview', v_ni,  'reference', v_nref),
      'nurture', jsonb_build_object('resume', v_nur, 'assessment', v_nua, 'interview', v_nui, 'reference', v_nuref),
      'drivers', jsonb_build_object('resume', v_dr,  'assessment', v_da,  'interview', v_di,  'reference', v_dref)
    ),
    'construct_weights', jsonb_build_object('nature', v_nature_w, 'nurture', v_nurture_w, 'drivers', v_drivers_w),
    'layer_weights_within_construct', jsonb_build_object(
      'nature',  jsonb_build_object('resume', v_nature_r_w,  'assessment', v_nature_a_w,  'interview', v_nature_i_w,  'reference', v_nature_ref_w),
      'nurture', jsonb_build_object('resume', v_nurture_r_w, 'assessment', v_nurture_a_w, 'interview', v_nurture_i_w, 'reference', v_nurture_ref_w),
      'drivers', jsonb_build_object('resume', v_drivers_r_w, 'assessment', v_drivers_a_w, 'interview', v_drivers_i_w, 'reference', v_drivers_ref_w)
    ),
    'layer_row_weights', jsonb_build_object(
      'resume',     jsonb_build_object('nature', v_row_r_nat,   'nurture', v_row_r_nur,   'drivers', v_row_r_dr),
      'assessment', jsonb_build_object('nature', v_row_a_nat,   'nurture', v_row_a_nur,   'drivers', v_row_a_dr),
      'interview',  jsonb_build_object('nature', v_row_i_nat,   'nurture', v_row_i_nur,   'drivers', v_row_i_dr),
      'reference',  jsonb_build_object('nature', v_row_ref_nat, 'nurture', v_row_ref_nur, 'drivers', v_row_ref_dr)
    ),
    'thresholds_used', jsonb_build_object(
      'framework_verdict', jsonb_build_object('hire', 75, 'consider', 60),
      'resume_layer',      jsonb_build_object('pass', 70, 'consider', 50),
      'other_layers',      jsonb_build_object('pass', 75, 'consider', 60)
    ),
    'assessment_target_role', v_ta.assessment_target_role,
    'best_fit_role',          v_best_fit_role,
    'best_fit_os',            v_best_fit_os,
    'best_role_category',     v_best_role_category,
    'display_label',          v_display_label,
    'lss_accuracy',           v_lss_acc,
    'reliability',            v_ta.reliability,
    'response_distortion',    v_ta.response_distortion
  );
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_three_construct_verdict(uuid) IS
'Suggs 4-layer x 3-construct verdict framework. All matrix inputs on 0-100 scale. Assessment cells sourced from v_hiring_candidates.assessment_nature/nurture/drivers (single source of truth with the Matrix Assessment ROW display). Nature falls back to best_fit_role''s OS when assessment_target_role is null. Interview cells from v_hiring_candidates.iv_*. Framework thresholds: hire >=75, consider >=60. Layer thresholds: resume pass >=70 / consider >=50, other layers pass >=75 / consider >=60.';


CREATE OR REPLACE FUNCTION public.hiregauge_three_construct_verdict_by_role(p_assessment_id uuid)
 RETURNS TABLE(assessment_id uuid, role text, role_display_label text, role_category text, role_os integer, is_best_fit boolean, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, nature_score numeric, nurture_score numeric, drivers_score numeric, character_floor_status text, character_floor_failed text[], retrospective_verdict text, retrospective_notes text, retrospective_context text, calibration_status text, dimensions_scored integer, confidence text, meta jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_ta record;
  v_bfr record;
  v_team_id uuid;
  v_is_active boolean;
  v_is_archived boolean;
  v_retro_context text;

  v_nr numeric; v_ni numeric; v_nref numeric;
  v_nur numeric; v_nua numeric; v_nui numeric; v_nuref numeric;
  v_dr numeric; v_di numeric; v_dref numeric;

  v_nature_r_w   numeric := 0.05; v_nature_a_w   numeric := 0.75; v_nature_i_w   numeric := 0.15; v_nature_ref_w   numeric := 0.05;
  v_nurture_r_w  numeric := 0.10; v_nurture_a_w  numeric := 0.15; v_nurture_i_w  numeric := 0.45; v_nurture_ref_w  numeric := 0.30;
  v_drivers_r_w  numeric := 0.10; v_drivers_a_w  numeric := 0.15; v_drivers_i_w  numeric := 0.45; v_drivers_ref_w  numeric := 0.30;
  v_nature_w numeric := 0.35; v_nurture_w numeric := 0.30; v_drivers_w numeric := 0.35;
  v_row_r_nat   numeric; v_row_r_nur   numeric; v_row_r_dr   numeric;
  v_row_a_nat   numeric; v_row_a_nur   numeric; v_row_a_dr   numeric;
  v_row_i_nat   numeric; v_row_i_nur   numeric; v_row_i_dr   numeric;
  v_row_ref_nat numeric; v_row_ref_nur numeric; v_row_ref_dr numeric;

  v_lss_acc numeric;
  v_dims_scored int := 0;
  v_char_floors_failed text[] := ARRAY[]::text[];
  v_char_floor_status text;
  v_retro_verdict text;
  v_calibration text;
  v_confidence text;

  v_role text;
  v_role_display text;
  v_role_category text;
  v_role_os integer;
  v_na numeric;
  v_da numeric;
  v_asmt_nurture numeric;
  v_asmt_drivers numeric;

  v_nature_score numeric; v_nurture_score numeric; v_drivers_score numeric;
  v_resume_score numeric; v_assessment_score numeric; v_interview_score numeric; v_reference_score numeric;
  v_score numeric;
  v_verdict text;

  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.v_hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT
    MAX(CASE WHEN layer='resume'     AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='resume'     AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='resume'     AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='assessment' AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='interview'  AND construct='drivers' THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='nature'  THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='nurture' THEN weight END),
    MAX(CASE WHEN layer='reference'  AND construct='drivers' THEN weight END)
  INTO
    v_row_r_nat, v_row_r_nur, v_row_r_dr,
    v_row_a_nat, v_row_a_nur, v_row_a_dr,
    v_row_i_nat, v_row_i_nur, v_row_i_dr,
    v_row_ref_nat, v_row_ref_nur, v_row_ref_dr
  FROM public.hiregauge_layer_composite_weights;

  SELECT * INTO v_bfr FROM public.cts_best_fit_role(p_assessment_id);

  SELECT t.id, (t.archived_at IS NULL AND COALESCE(t.is_active, false)), (t.archived_at IS NOT NULL)
    INTO v_team_id, v_is_active, v_is_archived
    FROM public.team t WHERE t.id = v_ta.team_member_id;
  v_retro_context := CASE WHEN v_is_active THEN 'hired_and_performing' WHEN v_is_archived THEN 'former_team' ELSE NULL END;

  IF v_ta.res_nature IS NOT NULL THEN v_nr := v_ta.res_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.res_nurture IS NOT NULL THEN v_nur := v_ta.res_nurture::numeric; END IF;
  IF v_ta.res_drivers IS NOT NULL THEN v_dr := v_ta.res_drivers::numeric; END IF;
  IF v_nr IS NULL AND v_ta.resume_quality IS NOT NULL THEN
    v_nr := 10 * v_ta.resume_quality::numeric;
    v_nur := 10 * v_ta.resume_quality::numeric;
    v_dr := 10 * v_ta.resume_quality::numeric;
    v_dims_scored := v_dims_scored + 1;
  END IF;

  -- Assessment nurture + drivers are role-invariant (view formula, single value).
  v_asmt_nurture := v_ta.assessment_nurture::numeric;
  v_asmt_drivers := v_ta.assessment_drivers::numeric;
  IF v_asmt_nurture IS NOT NULL THEN v_dims_scored := v_dims_scored + 1; END IF;
  IF v_asmt_drivers IS NOT NULL THEN v_dims_scored := v_dims_scored + 1; END IF;

  IF v_ta.iv_nature IS NOT NULL THEN v_ni := v_ta.iv_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.iv_nurture IS NOT NULL THEN v_nui := v_ta.iv_nurture::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.iv_drivers IS NOT NULL THEN v_di := v_ta.iv_drivers::numeric; v_dims_scored := v_dims_scored + 1; END IF;

  IF v_ta.char_honesty IS NOT NULL AND v_ta.char_honesty < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_honesty'); END IF;
  IF v_ta.char_hwe     IS NOT NULL AND v_ta.char_hwe     < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_hwe'); END IF;
  IF v_ta.char_persres IS NOT NULL AND v_ta.char_persres < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_persres'); END IF;
  IF v_ta.char_concern IS NOT NULL AND v_ta.char_concern < 7 THEN v_char_floors_failed := array_append(v_char_floors_failed, 'char_concern'); END IF;

  v_char_floor_status := CASE
    WHEN array_length(v_char_floors_failed, 1) > 0 THEN 'floor_failed'
    WHEN v_ta.char_honesty IS NOT NULL OR v_ta.char_hwe IS NOT NULL OR v_ta.char_persres IS NOT NULL OR v_ta.char_concern IS NOT NULL THEN 'floor_passed'
    ELSE 'not_scored'
  END;

  IF v_ta.ref_nature IS NOT NULL THEN v_nref := 10 * v_ta.ref_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.ref_nurture IS NOT NULL THEN v_nuref := 10 * v_ta.ref_nurture::numeric; v_dims_scored := v_dims_scored + 1; END IF;
  IF v_ta.ref_drivers IS NOT NULL THEN v_dref := 10 * v_ta.ref_drivers::numeric; v_dims_scored := v_dims_scored + 1; END IF;

  v_lss_acc := COALESCE(v_ta.lss_total_accuracy, 0);
  v_retro_verdict := COALESCE(v_ta.retrospective_verdict_override, 'not_scored');

  -- Nature increment fires once per candidate if any role's OS is non-null.
  IF v_ta.deadline_motivation IS NOT NULL THEN v_dims_scored := v_dims_scored + 1; END IF;

  v_confidence := CASE WHEN v_dims_scored >= 9 THEN 'high' WHEN v_dims_scored >= 5 THEN 'medium' ELSE 'low' END;

  FOR v_role, v_role_display, v_role_category, v_role_os IN
    SELECT r.role, r.display_label, r.category, r.os
    FROM (VALUES
      ('sales_outbound',       'Sales - Outbound',       'sales',     v_bfr.sales_outbound_os),
      ('sales_inbound',        'Sales - Inbound',        'sales',     v_bfr.sales_inbound_os),
      ('sales_in_book',        'Sales - In-Book',        'sales',     v_bfr.sales_in_book_os),
      ('retention_reception',  'Retention - Reception',  'retention', v_bfr.retention_reception_os),
      ('retention_escalation', 'Retention - Escalation', 'retention', v_bfr.retention_escalation_os),
      ('retention_support',    'Retention - Support',    'retention', v_bfr.retention_support_os),
      ('aspirant',             'Aspirant',               'aspirant',  v_bfr.aspirant_os)
    ) AS r(role, display_label, category, os)
  LOOP
    -- Per-role assessment nature = that role's OS (0-100). Nurture and drivers are
    -- role-invariant, pulled from view.
    v_na := CASE WHEN v_ta.deadline_motivation IS NOT NULL THEN v_role_os::numeric ELSE NULL END;
    v_da := v_asmt_drivers;

    v_wsum := 0; v_sum := 0;
    IF v_nr           IS NOT NULL THEN v_sum := v_sum + v_nr           * v_nature_r_w;   v_wsum := v_wsum + v_nature_r_w;   END IF;
    IF v_na           IS NOT NULL THEN v_sum := v_sum + v_na           * v_nature_a_w;   v_wsum := v_wsum + v_nature_a_w;   END IF;
    IF v_ni           IS NOT NULL THEN v_sum := v_sum + v_ni           * v_nature_i_w;   v_wsum := v_wsum + v_nature_i_w;   END IF;
    IF v_nref         IS NOT NULL THEN v_sum := v_sum + v_nref         * v_nature_ref_w; v_wsum := v_wsum + v_nature_ref_w; END IF;
    v_nature_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nur          IS NOT NULL THEN v_sum := v_sum + v_nur          * v_nurture_r_w;   v_wsum := v_wsum + v_nurture_r_w;   END IF;
    IF v_asmt_nurture IS NOT NULL THEN v_sum := v_sum + v_asmt_nurture * v_nurture_a_w;   v_wsum := v_wsum + v_nurture_a_w;   END IF;
    IF v_nui          IS NOT NULL THEN v_sum := v_sum + v_nui          * v_nurture_i_w;   v_wsum := v_wsum + v_nurture_i_w;   END IF;
    IF v_nuref        IS NOT NULL THEN v_sum := v_sum + v_nuref        * v_nurture_ref_w; v_wsum := v_wsum + v_nurture_ref_w; END IF;
    v_nurture_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_dr   IS NOT NULL THEN v_sum := v_sum + v_dr   * v_drivers_r_w;   v_wsum := v_wsum + v_drivers_r_w;   END IF;
    IF v_da   IS NOT NULL THEN v_sum := v_sum + v_da   * v_drivers_a_w;   v_wsum := v_wsum + v_drivers_a_w;   END IF;
    IF v_di   IS NOT NULL THEN v_sum := v_sum + v_di   * v_drivers_i_w;   v_wsum := v_wsum + v_drivers_i_w;   END IF;
    IF v_dref IS NOT NULL THEN v_sum := v_sum + v_dref * v_drivers_ref_w; v_wsum := v_wsum + v_drivers_ref_w; END IF;
    v_drivers_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nr  IS NOT NULL THEN v_sum := v_sum + v_nr  * v_row_r_nat; v_wsum := v_wsum + v_row_r_nat; END IF;
    IF v_nur IS NOT NULL THEN v_sum := v_sum + v_nur * v_row_r_nur; v_wsum := v_wsum + v_row_r_nur; END IF;
    IF v_dr  IS NOT NULL THEN v_sum := v_sum + v_dr  * v_row_r_dr;  v_wsum := v_wsum + v_row_r_dr;  END IF;
    v_resume_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_na           IS NOT NULL THEN v_sum := v_sum + v_na           * v_row_a_nat; v_wsum := v_wsum + v_row_a_nat; END IF;
    IF v_asmt_nurture IS NOT NULL THEN v_sum := v_sum + v_asmt_nurture * v_row_a_nur; v_wsum := v_wsum + v_row_a_nur; END IF;
    IF v_da           IS NOT NULL THEN v_sum := v_sum + v_da           * v_row_a_dr;  v_wsum := v_wsum + v_row_a_dr;  END IF;
    v_assessment_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_ni  IS NOT NULL THEN v_sum := v_sum + v_ni  * v_row_i_nat; v_wsum := v_wsum + v_row_i_nat; END IF;
    IF v_nui IS NOT NULL THEN v_sum := v_sum + v_nui * v_row_i_nur; v_wsum := v_wsum + v_row_i_nur; END IF;
    IF v_di  IS NOT NULL THEN v_sum := v_sum + v_di  * v_row_i_dr;  v_wsum := v_wsum + v_row_i_dr;  END IF;
    v_interview_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nref  IS NOT NULL THEN v_sum := v_sum + v_nref  * v_row_ref_nat; v_wsum := v_wsum + v_row_ref_nat; END IF;
    IF v_nuref IS NOT NULL THEN v_sum := v_sum + v_nuref * v_row_ref_nur; v_wsum := v_wsum + v_row_ref_nur; END IF;
    IF v_dref  IS NOT NULL THEN v_sum := v_sum + v_dref  * v_row_ref_dr;  v_wsum := v_wsum + v_row_ref_dr;  END IF;
    v_reference_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_wsum := 0; v_sum := 0;
    IF v_nature_score  IS NOT NULL THEN v_sum := v_sum + v_nature_score  * v_nature_w;  v_wsum := v_wsum + v_nature_w;  END IF;
    IF v_nurture_score IS NOT NULL THEN v_sum := v_sum + v_nurture_score * v_nurture_w; v_wsum := v_wsum + v_nurture_w; END IF;
    IF v_drivers_score IS NOT NULL THEN v_sum := v_sum + v_drivers_score * v_drivers_w; v_wsum := v_wsum + v_drivers_w; END IF;
    v_score := CASE WHEN v_wsum > 0 THEN v_sum / v_wsum ELSE NULL END;

    v_verdict := CASE
      WHEN v_char_floor_status = 'floor_failed' THEN 'decline_character'
      WHEN v_score IS NULL THEN 'insufficient_data'
      WHEN v_score >= 75 THEN 'hire'
      WHEN v_score >= 60 THEN 'consider'
      ELSE 'decline'
    END;

    v_calibration := CASE
      WHEN v_retro_verdict = 'not_scored' THEN 'no_retrospective'
      WHEN v_retro_verdict = 'pass' AND v_verdict IN ('hire','consider') THEN 'framework_agrees_positive'
      WHEN v_retro_verdict = 'fail_confirmed' AND v_verdict IN ('decline','decline_character') THEN 'framework_agrees_negative'
      WHEN v_retro_verdict = 'pass' AND v_verdict IN ('decline','decline_character') THEN 'framework_missed_positive'
      WHEN v_retro_verdict = 'fail_confirmed' AND v_verdict IN ('hire','consider') THEN 'framework_missed_negative'
      WHEN v_retro_verdict = 'flag' THEN 'partial'
      ELSE 'no_retrospective'
    END;

    assessment_id := p_assessment_id;
    role := v_role;
    role_display_label := v_role_display;
    role_category := v_role_category;
    role_os := v_role_os;
    is_best_fit := (v_role = v_bfr.best_role);
    verdict := v_verdict;
    score_0_10 := v_score;
    score_hire_at_70 := CASE WHEN v_score IS NULL THEN 'n/a' WHEN v_score >= 70 THEN 'hire' WHEN v_score >= 55 THEN 'consider' ELSE 'decline' END;
    score_hire_at_75 := CASE WHEN v_score IS NULL THEN 'n/a' WHEN v_score >= 75 THEN 'hire' WHEN v_score >= 60 THEN 'consider' ELSE 'decline' END;
    score_hire_at_80 := CASE WHEN v_score IS NULL THEN 'n/a' WHEN v_score >= 80 THEN 'hire' WHEN v_score >= 65 THEN 'consider' ELSE 'decline' END;
    resume_score := v_resume_score;
    resume_verdict := CASE
      WHEN v_resume_score IS NULL THEN 'not_scored'
      WHEN v_resume_score >= 70 THEN 'pass'
      WHEN v_resume_score >= 50 THEN 'consider'
      ELSE 'decline'
    END;
    assessment_score := v_assessment_score;
    assessment_verdict := CASE
      WHEN v_assessment_score IS NULL THEN 'not_scored'
      WHEN v_assessment_score >= 75 THEN 'pass'
      WHEN v_assessment_score >= 60 THEN 'consider'
      ELSE 'decline'
    END;
    interview_score := v_interview_score;
    interview_verdict := CASE
      WHEN v_interview_score IS NULL THEN 'not_scored'
      WHEN v_char_floor_status = 'floor_failed' THEN 'decline_character'
      WHEN v_interview_score >= 75 THEN 'pass'
      WHEN v_interview_score >= 60 THEN 'consider'
      ELSE 'decline'
    END;
    reference_score := v_reference_score;
    reference_verdict := CASE
      WHEN v_reference_score IS NULL THEN 'not_scored'
      WHEN v_reference_score >= 75 THEN 'pass'
      WHEN v_reference_score >= 60 THEN 'consider'
      ELSE 'decline'
    END;
    nature_score := v_nature_score;
    nurture_score := v_nurture_score;
    drivers_score := v_drivers_score;
    character_floor_status := v_char_floor_status;
    character_floor_failed := v_char_floors_failed;
    retrospective_verdict := v_retro_verdict;
    retrospective_notes := v_ta.retrospective_notes;
    retrospective_context := v_retro_context;
    calibration_status := v_calibration;
    dimensions_scored := v_dims_scored;
    confidence := v_confidence;
    meta := jsonb_build_object(
      'matrix', jsonb_build_object(
        'nature',  jsonb_build_object('resume', v_nr,  'assessment', v_na,           'interview', v_ni,  'reference', v_nref),
        'nurture', jsonb_build_object('resume', v_nur, 'assessment', v_asmt_nurture, 'interview', v_nui, 'reference', v_nuref),
        'drivers', jsonb_build_object('resume', v_dr,  'assessment', v_da,           'interview', v_di,  'reference', v_dref)
      ),
      'construct_weights', jsonb_build_object('nature', v_nature_w, 'nurture', v_nurture_w, 'drivers', v_drivers_w),
      'layer_weights_within_construct', jsonb_build_object(
        'nature',  jsonb_build_object('resume', v_nature_r_w,  'assessment', v_nature_a_w,  'interview', v_nature_i_w,  'reference', v_nature_ref_w),
        'nurture', jsonb_build_object('resume', v_nurture_r_w, 'assessment', v_nurture_a_w, 'interview', v_nurture_i_w, 'reference', v_nurture_ref_w),
        'drivers', jsonb_build_object('resume', v_drivers_r_w, 'assessment', v_drivers_a_w, 'interview', v_drivers_i_w, 'reference', v_drivers_ref_w)
      ),
      'layer_row_weights', jsonb_build_object(
        'resume',     jsonb_build_object('nature', v_row_r_nat,   'nurture', v_row_r_nur,   'drivers', v_row_r_dr),
        'assessment', jsonb_build_object('nature', v_row_a_nat,   'nurture', v_row_a_nur,   'drivers', v_row_a_dr),
        'interview',  jsonb_build_object('nature', v_row_i_nat,   'nurture', v_row_i_nur,   'drivers', v_row_i_dr),
        'reference',  jsonb_build_object('nature', v_row_ref_nat, 'nurture', v_row_ref_nur, 'drivers', v_row_ref_dr)
      ),
      'thresholds_used', jsonb_build_object(
        'framework_verdict', jsonb_build_object('hire', 75, 'consider', 60),
        'resume_layer',      jsonb_build_object('pass', 70, 'consider', 50),
        'other_layers',      jsonb_build_object('pass', 75, 'consider', 60)
      ),
      'assessment_target_role', v_ta.assessment_target_role,
      'best_fit_role',          v_bfr.best_role,
      'best_fit_role_display',  v_bfr.display_label,
      'best_fit_role_category', v_bfr.best_role_category,
      'best_fit_role_os',       v_bfr.best_os,
      'lss_accuracy',           v_lss_acc,
      'reliability',            v_ta.reliability,
      'response_distortion',    v_ta.response_distortion
    );
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_three_construct_verdict_by_role(uuid) IS
'Per-role variant. Each role loop uses that role''s own OS as v_na (assessment nature cell). v_nua and v_da are role-invariant, sourced from view.assessment_nurture / view.assessment_drivers. All matrix inputs on 0-100 scale. Interview inputs from v_hiring_candidates.iv_*.';
