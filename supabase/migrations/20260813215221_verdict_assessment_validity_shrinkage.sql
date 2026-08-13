DROP FUNCTION IF EXISTS public.verdict_assessment(uuid, text);

CREATE OR REPLACE FUNCTION public.verdict_assessment(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text, protocol_validity jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Validity-conditioned shrinkage on Character and Commitment (added
2026-08-13, companion to role_fit_v5_1 weighting in
_newtworks_role_fit_core). Character and Commitment are built entirely
from self-report facets -- no gma/sjt input exists in either construct for
down-weighted evidence to renormalize into (unlike role fit / Capability,
which does have gma/sjt to absorb the shift). Kelley's regressed
true-score estimation is used instead: as protocol validity v drops, each
construct's raw score is pulled toward the population-mean anchor (50 on
the percentile scale) rather than reweighted internally.

  construct_final = ROUND( v * construct_raw + (1 - v) * 50 , 2 )

Citations: Kelley 1927; Nunnally & Bernstein 1994 (regressed/shrunk
estimation under measurement unreliability). This is symmetric -- an
untrustworthy LOW score also moves toward 50, same as an untrustworthy
high score would -- and is explicitly NOT a claim to recover the
candidate's true honest score (Ellingson, Sackett & Hough 1999 still
governs that point; stored candidate values are never altered by this
function). v=1.00 leaves the construct mathematically unchanged.

Capability_score is NOT shrunk here -- it already carries v through role
fit's own weight renormalization (_newtworks_role_fit_core /
_newtworks_protocol_validity). Applying shrinkage to capability here too
would double-apply v to the same evidence.

Same v (from _newtworks_protocol_validity) is applied exactly once per
construct, via the mechanism appropriate to that construct's structure.
*/
DECLARE
  v_candidate hiring_candidates;
  v_validity jsonb;
  v_v numeric;
  v_cap numeric; v_chr_raw numeric; v_com_raw numeric;
  v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;
  v_validity := public._newtworks_protocol_validity(v_candidate);
  v_v := (v_validity->>'v')::numeric;

  v_cap := public.assessment_capability(p_candidate_id, p_role);
  v_chr_raw := public.assessment_character(p_candidate_id);
  v_com_raw := public.assessment_commitment(p_candidate_id);

  v_chr := CASE WHEN v_chr_raw IS NULL THEN NULL ELSE ROUND(v_v * v_chr_raw + (1 - v_v) * 50, 2) END;
  v_com := CASE WHEN v_com_raw IS NULL THEN NULL ELSE ROUND(v_v * v_com_raw + (1 - v_v) * 50, 2) END;

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
  protocol_validity := v_validity;
  RETURN NEXT;
END;
$function$;
