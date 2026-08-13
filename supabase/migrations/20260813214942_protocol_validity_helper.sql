CREATE OR REPLACE FUNCTION public._newtworks_protocol_validity(p_candidate hiring_candidates)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
/*
Validity-conditioned evidence weighting of the self-report layer -- NOT
score correction. Down-weights self-report facet inputs when their
validity is threatened by faking-good or careless/unreliable responding;
GMA and SJT (harder-to-fake, contextualized measures) absorb the shifted
weight via existing renormalization in _newtworks_role_fit_core, and via
regressed-mean shrinkage in verdict_assessment for Character and
Commitment (the two constructs built entirely from self-report facets,
with no gma/sjt input to renormalize into). Stored candidate values are
NEVER altered by this function or its consumers -- this is evidence
weighting, not individual score correction.

Citations:
- Mueller-Hanson, Heggestad & Thornton 2003 JAP -- faking on self-report
  personality measures degrades criterion-related validity.
- Komar, Brown, Komar & Robie 2008 -- faking attenuates predictive
  validity of personality-based criterion relationships.
- Ellingson, Sackett & Hough 1999 JAP -- individual-level social
  desirability score correction does NOT recover an honest score and does
  not improve prediction; this approach was explicitly rejected. This
  function never alters an individual's stored score -- it reduces
  evidentiary weight in downstream scoring only.
- Meade & Craig 2012 Psychological Methods -- careless/inattentive
  responding degrades measurement quality broadly, independent of
  intentional faking; motivates the separate reliability multiplier.

Multiplier magnitudes below (im_mult, rel_mult bands) are calibration
values set at build time, not derived from Newtworks outcome data.
Recalibration checkpoint: N=50 assessed candidates.
*/
DECLARE
  v_im_mult numeric;
  v_rel_mult numeric;
  v_v numeric;
  v_label text;
BEGIN
  v_im_mult := CASE p_candidate.impression_management_band
    WHEN 'typical' THEN 1.00
    WHEN 'elevated' THEN 0.75
    WHEN 'very_elevated' THEN 0.50
    ELSE 1.00
  END;

  v_rel_mult := CASE p_candidate.reliability
    WHEN 'high' THEN 1.00
    WHEN 'moderate' THEN 0.85
    WHEN 'low' THEN 0.50
    ELSE 1.00
  END;

  v_v := ROUND(GREATEST(0.30, v_im_mult * v_rel_mult), 2);

  v_label := CASE
    WHEN v_v >= 0.95 THEN 'high'
    WHEN v_v >= 0.60 THEN 'reduced'
    ELSE 'low'
  END;

  RETURN jsonb_build_object(
    'v', v_v,
    'im_mult', v_im_mult,
    'rel_mult', v_rel_mult,
    'label', v_label
  );
END;
$function$;
