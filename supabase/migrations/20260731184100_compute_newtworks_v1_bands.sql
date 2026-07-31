-- Roll up the four existing signal functions into two candidate-level ratings:
-- reliability (data quality / engagement) and response_distortion (faking-good bias).
-- Reliability signals: straight-lining, speed-through, low item count, acquiescence.
-- Distortion signals: fake-vocab endorsement (count-based, works at any pool size),
-- and the look-good scale (gated at 10+ items — below that the score is too noisy to trust).
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_bands(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL,
  p_sitting integer DEFAULT NULL
)
RETURNS TABLE(reliability text, response_distortion text)
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  d record;
  im record;
  nn record;
  fake_signal text;
  look_good_signal text;
  reliability_out text;
  distortion_out text;
BEGIN
  SELECT * INTO d  FROM public.compute_newtworks_v1_distortion_signals(p_candidate_id, p_stint, p_sitting);
  SELECT * INTO im FROM public.compute_newtworks_v1_impression_mgmt_score (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO nn FROM public.compute_newtworks_v1_nonsense_inflation    (p_candidate_id, p_stint, p_sitting);

  -- No Likert data at all → unassessable; return nulls
  IF (d.n_likert_items IS NULL OR d.n_likert_items = 0) THEN
    RETURN QUERY SELECT NULL::text, NULL::text;
    RETURN;
  END IF;

  -- ============================================================
  -- Reliability: did they engage seriously with the assessment?
  -- ============================================================
  IF COALESCE(d.straight_line_flag, false)
     OR COALESCE(d.straight_through_flag, false)
     OR d.n_likert_items < 20 THEN
    reliability_out := 'low';
  ELSIF COALESCE(d.acquiescence_flag, false)
     OR d.n_likert_items < 30 THEN
    reliability_out := 'moderate';
  ELSE
    reliability_out := 'high';
  END IF;

  -- ============================================================
  -- Distortion: did they try to look better than they are?
  -- ============================================================
  -- Fake-vocab signal (count-based; endorsing a made-up word is telling
  -- at any pool size — Paulhus et al. 2003)
  IF nn.n_nonsense_items IS NULL OR nn.n_nonsense_items = 0 THEN
    fake_signal := NULL;
  ELSIF COALESCE(nn.inflation_count, 0) >= 2 THEN
    fake_signal := 'high';
  ELSIF COALESCE(nn.inflation_count, 0) = 1 THEN
    fake_signal := 'moderate';
  ELSE
    fake_signal := 'clean';
  END IF;

  -- Look-good signal (gated at 10+ items per Sackett & Lievens 2008 —
  -- below 10 the score is too noisy to use for a hiring decision)
  IF im.n_items IS NULL OR im.n_items < 10 OR im.score_0_100 IS NULL THEN
    look_good_signal := NULL;
  ELSIF im.score_0_100 >= 75 THEN
    look_good_signal := 'high';
  ELSIF im.score_0_100 >= 60 THEN
    look_good_signal := 'moderate';
  ELSE
    look_good_signal := 'clean';
  END IF;

  -- Combine: worst concern wins
  IF fake_signal = 'high' OR look_good_signal = 'high' THEN
    distortion_out := 'high';
  ELSIF fake_signal = 'moderate' OR look_good_signal = 'moderate' THEN
    distortion_out := 'moderate';
  ELSIF fake_signal = 'clean' OR look_good_signal = 'clean' THEN
    distortion_out := 'low';
  ELSE
    distortion_out := NULL;  -- both signals silent
  END IF;

  RETURN QUERY SELECT reliability_out, distortion_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.compute_newtworks_v1_bands(uuid, integer, integer) TO service_role, anon, authenticated;
