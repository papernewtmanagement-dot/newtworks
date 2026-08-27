CREATE OR REPLACE FUNCTION public.verdict_assessment(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text, protocol_validity jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
2026-08-13 single-source refactor. Shrinkage no longer happens here: it moved into
the construct functions themselves (_assessment_character_parts /
assessment_commitment via _newtworks_shrink), so assessment_character() and
assessment_commitment() ARE the one Character and Commitment number everywhere --
detail page, board, gap triggers, this verdict. This function only weights the three
construct outputs per hiregauge_layer_composite_weights and labels the verdict.
Capability carries validity through role fit's own weight renormalization
(_newtworks_role_fit_core) and is never shrunk -- doing both would double-apply v to
the same evidence (unchanged rule). SECURITY DEFINER for the same per-row RLS cost
reason as the leaf construct functions (20260813224026).

2026-08-25 (Peter directive): NO PARTIAL VERDICTS. A candidate who has not finished
the whole assessment (assessment_completed_at IS NULL -- finalize sets it only once
every stint is answered) gets NULL for every output. Before this, the weight
renormalization below happily built a composite out of whichever sections happened
to be done, which is how wiped-personality candidates kept a board score.
*/
DECLARE
  v_candidate hiring_candidates;
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;

  IF v_candidate.id IS NULL OR v_candidate.assessment_completed_at IS NULL THEN
    capability_score := NULL; character_score := NULL; commitment_score := NULL;
    composite := NULL; verdict := NULL; protocol_validity := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  v_cap := public.assessment_capability(p_candidate_id, p_role);
  v_chr := public.assessment_character(p_candidate_id);
  v_com := public.assessment_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='assessment';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('assessment', composite);
  protocol_validity := public._newtworks_protocol_validity(v_candidate);
  RETURN NEXT;
END;
$function$;
