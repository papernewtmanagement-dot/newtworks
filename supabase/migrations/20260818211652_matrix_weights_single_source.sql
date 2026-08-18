-- 2026-08-18 — Candidate Detail layer-matrix weighting audit, part 2 of 2.
--
-- ONE weight matrix. hiregauge_layer_composite_weights now holds the CELL weights of the
-- 5 layer x 3 construct matrix: for each construct, how much of that construct's total each
-- layer contributes (each construct's five weights sum to 1.00). Until now the same matrix
-- lived twice — as hard-coded constants inside verdict_overall (the column direction, which
-- drives the verdict) and as separately hand-set "normalized within-layer" rows in this
-- table (the row direction, which drives each layer's Total + pill). The two had drifted:
--   interview  table 14.29/42.86/42.86 (from the .15/.45/.45 era) vs cells 15/40/40
--   reference  table  9.09/54.55/36.36 (pre-2026-07-19 era)       vs cells  5/30/25
--   screen     table 50/50 (set 2026-08-13)                        vs cells  0/ 5/10
-- so the "weight NN%" printed on a cell and the weight actually used for that row's Total
-- disagreed, and layer Totals no longer averaged up to the overall. Resume (5/10/10 -> 20/40/40)
-- and assessment (75/15/15 -> 71.4/14.3/14.3) still matched only because nobody had touched
-- their columns since the table was last synced.
--
-- Now: verdict_overall READS this table for its column weights, and the five verdict_<layer>
-- functions keep reading it for their row totals — they already divide by the sum of the
-- weights present (renormalize on read), so un-normalized cell weights give exactly the
-- normalized-row-profile total (interview 15.8/42.1/42.1, reference 8.3/50.0/41.7,
-- screen 33.3/66.7, resume 20/40/40, assessment 71.4/14.3/14.3). Row totals therefore average
-- up to the overall by construction. Nothing to sync, nowhere to drift.
--
-- Column weights are UNCHANGED (research-audited 2026-08-13, 4 challenged adjustments
-- rejected). Construct weights stay equal thirds (locked 2026-08-05, Wainer 1976) as
-- constants in verdict_overall. Overall verdict / overall score / construct totals: zero drift.
-- Layer totals that move: screen (17 scored, mean 2.9 pts, 2 pills flip), interview (1 scored,
-- 0.14 pt, no flip), reference (0 scored). verdict_resume no longer reads this table at all
-- (part 1) — its composite is the canonical signal-direct resume composite; the resume row
-- here now exists purely as the resume layer's column weights inside verdict_overall.
--
-- Guard: a deferred constraint trigger refuses any commit where a construct's five weights
-- do not sum to 1.00 (+/-0.0005), so the printed "weight NN%" labels stay true shares.
-- Retune a cell by editing this table in a migration and rebalancing its column; never edit
-- verdict_overall constants.

-- 1) Repurpose the rows: cell weights (within-construct, per layer).
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.0500, updated_at = now() WHERE layer='resume'     AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1000, updated_at = now() WHERE layer='resume'     AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1000, updated_at = now() WHERE layer='resume'     AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.7500, updated_at = now() WHERE layer='assessment' AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1500, updated_at = now() WHERE layer='assessment' AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1500, updated_at = now() WHERE layer='assessment' AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1500, updated_at = now() WHERE layer='interview'  AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4000, updated_at = now() WHERE layer='interview'  AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.4000, updated_at = now() WHERE layer='interview'  AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.0500, updated_at = now() WHERE layer='reference'  AND construct='capability';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.3000, updated_at = now() WHERE layer='reference'  AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.2500, updated_at = now() WHERE layer='reference'  AND construct='commitment';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.0500, updated_at = now() WHERE layer='screen'     AND construct='character';
UPDATE public.hiregauge_layer_composite_weights SET weight = 0.1000, updated_at = now() WHERE layer='screen'     AND construct='commitment';
INSERT INTO public.hiregauge_layer_composite_weights (layer, construct, weight)
VALUES ('screen', 'capability', 0.0000)
ON CONFLICT (layer, construct) DO UPDATE SET weight = EXCLUDED.weight, updated_at = now();

COMMENT ON TABLE public.hiregauge_layer_composite_weights IS
  'THE HireGauge weight matrix (5 layers x 3 constructs), single source. weight = share of the CONSTRUCT total that this LAYER contributes; each construct''s five weights sum to 1.00 (enforced by trg_hlcw_construct_sums). verdict_overall reads these as its column weights (construct totals -> overall, constructs equal thirds). verdict_resume/assessment/interview/reference/screen read the same rows for their row totals and divide by the weights present, so a layer''s Total is that layer''s normalized contribution profile and layer totals average up to the overall. Repurposed 2026-08-18 from separately-maintained normalized within-layer rows (which had drifted); construct rename trap (PK + CHECK on literal construct names) still applies.';

-- 2) Guard: each construct's five weights must sum to 1.00 at commit.
CREATE OR REPLACE FUNCTION public._hlcw_check_construct_sums()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(construct || '=' || round(s, 4)::text, ', ')
    INTO v_bad
    FROM (SELECT construct, sum(weight) AS s FROM public.hiregauge_layer_composite_weights GROUP BY construct) t
   WHERE abs(s - 1.0) > 0.0005;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'hiregauge_layer_composite_weights: each construct''s layer weights must sum to 1.00 — off: %', v_bad
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_hlcw_construct_sums ON public.hiregauge_layer_composite_weights;
CREATE CONSTRAINT TRIGGER trg_hlcw_construct_sums
  AFTER INSERT OR UPDATE OR DELETE ON public.hiregauge_layer_composite_weights
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public._hlcw_check_construct_sums();

-- 3) verdict_overall reads the matrix from the table (no more constants).
CREATE OR REPLACE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, capability_score numeric, character_score numeric, commitment_score numeric, dimensions_scored integer, confidence text, meta jsonb, screen_score numeric, screen_verdict text)
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
2026-08-18: layer-within-construct weights are read from hiregauge_layer_composite_weights
(the ONE weight matrix; see its table comment) instead of being hard-coded here. The five
verdict_<layer> functions read the same rows for their row totals, so cell labels, row totals,
construct totals and the overall all come from one matrix. Construct weights stay equal
thirds (locked 2026-08-05; Wainer 1976 — near-equal weights are robust absent a large local
validation sample; character carries the strongest single validity coefficient in the
framework's own literature, Ones/Viswesvaran/Schmidt 1993, so there is no basis to weight it
below the other two). Every construct total renormalizes over the layers actually scored;
the overall renormalizes over the constructs actually scored (dimensions_scored / confidence
tell the reader how much of the matrix is filled).
*/
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record; v_s record;
  v_dims int := 0;
  v_cap_r_w numeric; v_cap_a_w numeric; v_cap_i_w numeric; v_cap_ref_w numeric; v_cap_s_w numeric;
  v_chr_r_w numeric; v_chr_a_w numeric; v_chr_i_w numeric; v_chr_ref_w numeric; v_chr_s_w numeric;
  v_com_r_w numeric; v_com_a_w numeric; v_com_i_w numeric; v_com_ref_w numeric; v_com_s_w numeric;
  v_cap_w numeric := 1.0/3; v_chr_w numeric := 1.0/3; v_com_w numeric := 1.0/3;
  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT
    COALESCE(max(CASE WHEN layer='resume'     AND construct='capability' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='assessment' AND construct='capability' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='interview'  AND construct='capability' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='reference'  AND construct='capability' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='screen'     AND construct='capability' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='resume'     AND construct='character'  THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='assessment' AND construct='character'  THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='interview'  AND construct='character'  THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='reference'  AND construct='character'  THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='screen'     AND construct='character'  THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='resume'     AND construct='commitment' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='assessment' AND construct='commitment' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='interview'  AND construct='commitment' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='reference'  AND construct='commitment' THEN weight END), 0),
    COALESCE(max(CASE WHEN layer='screen'     AND construct='commitment' THEN weight END), 0)
  INTO
    v_cap_r_w, v_cap_a_w, v_cap_i_w, v_cap_ref_w, v_cap_s_w,
    v_chr_r_w, v_chr_a_w, v_chr_i_w, v_chr_ref_w, v_chr_s_w,
    v_com_r_w, v_com_a_w, v_com_i_w, v_com_ref_w, v_com_s_w
  FROM public.hiregauge_layer_composite_weights;

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
  IF v_s.capability_score   IS NOT NULL THEN v_sum := v_sum + v_s.capability_score   * v_cap_s_w;   v_wsum := v_wsum + v_cap_s_w;   END IF;
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
    'weights_source', 'hiregauge_layer_composite_weights (single matrix; layer totals normalize the same rows on read) -- 2026-08-18',
    'layer_weights_within_construct', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_cap_r_w, 'assessment', v_cap_a_w, 'interview', v_cap_i_w, 'reference', v_cap_ref_w, 'screen', v_cap_s_w),
      'character',  jsonb_build_object('resume', v_chr_r_w, 'assessment', v_chr_a_w, 'interview', v_chr_i_w, 'reference', v_chr_ref_w, 'screen', v_chr_s_w),
      'commitment', jsonb_build_object('resume', v_com_r_w, 'assessment', v_com_a_w, 'interview', v_com_i_w, 'reference', v_com_ref_w, 'screen', v_com_s_w)),
    'role_used_for_assessment_capability', COALESCE(p_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_score', v_best.best_fit_score);
  RETURN NEXT;
END;
$function$;
