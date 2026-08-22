-- Research-aligned rewrite (Peter directive 2026-07-31 pt 2):
-- Reliability MODERATE requires TWO or more mild indicators converging
-- (Curran 2016 multi-indicator careless-responding detection).
-- Added between-scale non-differentiation check (Ehrhart et al. 2009).
-- Tightened look-good MODERATE cutoff from 60 to 65 (Booth-Kewley et al. 1992
-- +0.75 SD above normative mean = ~65 on 0-100 scale).
-- Added convergence-HIGH for distortion when both mild signals fire
-- (Paulhus 2002 multi-indicator convergence).
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

  n_traits_low_sd int;
  between_scale_sd numeric;
  mild_indicator_count int;
  trait_scores numeric[];
BEGIN
  SELECT * INTO d  FROM public.compute_newtworks_v1_distortion_signals(p_candidate_id, p_stint, p_sitting);
  SELECT * INTO im FROM public.compute_newtworks_v1_impression_mgmt_score (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO nn FROM public.compute_newtworks_v1_nonsense_inflation    (p_candidate_id, p_stint, p_sitting);

  -- No Likert data at all → unassessable; return nulls
  IF (d.n_likert_items IS NULL OR d.n_likert_items = 0) THEN
    RETURN QUERY SELECT NULL::text, NULL::text;
    RETURN;
  END IF;

  -- Count traits with within-trait SD below 0.4 (Curran 2016 direction;
  -- 0.4 threshold is judgment on a 1-5 Likert scale)
  SELECT COUNT(*) INTO n_traits_low_sd
  FROM public.compute_newtworks_v1_reliability_per_candidate(p_candidate_id, p_stint, p_sitting)
  WHERE within_trait_sd IS NOT NULL AND within_trait_sd < 0.4;

  -- Between-scale SD across the 9 stored personality trait scores
  -- (Ehrhart et al. 2009 non-differentiation check; SD<0.5 on 5-point = <5 on 0-100)
  SELECT ARRAY[hc.analytical, hc.assertiveness, hc.belief_in_others, hc.compassion,
               hc.deadline_motivation, hc.independent_spirit, hc.optimism,
               hc.recognition_drive, hc.self_promotion]::numeric[]
  INTO trait_scores
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;

  SELECT stddev_samp(v)::numeric INTO between_scale_sd
  FROM unnest(trait_scores) v
  WHERE v IS NOT NULL;

  -- ============================================================
  -- Reliability: did they engage seriously with the assessment?
  -- ============================================================
  -- LOW: any strong indicator (Meade & Craig 2012 for straight-line + overall
  -- variance; Huang et al. 2012 for speed-through; judgment on <20 items)
  IF COALESCE(d.straight_line_flag, false)
     OR COALESCE(d.straight_through_flag, false)
     OR d.n_likert_items < 20 THEN
    reliability_out := 'low';
  ELSE
    -- MODERATE: two or more mild indicators must converge
    -- (Curran 2016 multi-indicator careless-responding rule)
    mild_indicator_count := 0;

    -- Mild long-string: max same-answer run 5-7 (Meade & Craig 2012 secondary)
    IF COALESCE(d.max_consecutive_run, 0) BETWEEN 5 AND 7 THEN
      mild_indicator_count := mild_indicator_count + 1;
    END IF;

    -- Acquiescence: mean Likert deviates >0.75 from neutral
    -- (Podsakoff et al. 2003 direction; 0.75 threshold is judgment,
    -- Baumgartner & Steenkamp 2001 uses 1.0)
    IF COALESCE(d.acquiescence_flag, false) THEN
      mild_indicator_count := mild_indicator_count + 1;
    END IF;

    -- Within-scale non-differentiation: majority of the 9 traits show low
    -- within-trait variance (Curran 2016 majority-of-scales rule;
    -- 5-of-9 = smallest majority, 0.4 SD threshold is judgment)
    IF n_traits_low_sd >= 5 THEN
      mild_indicator_count := mild_indicator_count + 1;
    END IF;

    -- Between-scale non-differentiation: candidate did not discriminate
    -- across traits (Ehrhart et al. 2009; threshold research-cited)
    IF between_scale_sd IS NOT NULL AND between_scale_sd < 5 THEN
      mild_indicator_count := mild_indicator_count + 1;
    END IF;

    -- Insufficient data density: under 50% of typical expected (~80 items)
    -- (Curran 2016 minimum-density direction; 50 threshold is judgment)
    IF d.n_likert_items < 50 THEN
      mild_indicator_count := mild_indicator_count + 1;
    END IF;

    IF mild_indicator_count >= 2 THEN
      reliability_out := 'moderate';
    ELSE
      reliability_out := 'high';
    END IF;
  END IF;

  -- ============================================================
  -- Distortion: did they try to look better than they are?
  -- ============================================================
  -- Fake-vocab signal (Paulhus et al. 2003 over-claiming technique;
  -- 2+ = bias ≥0.25 on 8-word pool, research-supported concerning threshold)
  IF nn.n_nonsense_items IS NULL OR nn.n_nonsense_items = 0 THEN
    fake_signal := NULL;
  ELSIF COALESCE(nn.inflation_count, 0) >= 2 THEN
    fake_signal := 'high';
  ELSIF COALESCE(nn.inflation_count, 0) = 1 THEN
    fake_signal := 'moderate';
  ELSE
    fake_signal := 'clean';
  END IF;

  -- Look-good signal (Booth-Kewley et al. 1992 impression-management cutoffs:
  -- +0.75 SD ≈ 65 on 0-100; +1.5 SD ≈ 75 on 0-100. Gated at 10+ items
  -- per Sackett & Lievens 2008)
  IF im.n_items IS NULL OR im.n_items < 10 OR im.score_0_100 IS NULL THEN
    look_good_signal := NULL;
  ELSIF im.score_0_100 >= 75 THEN
    look_good_signal := 'high';
  ELSIF im.score_0_100 >= 65 THEN
    look_good_signal := 'moderate';
  ELSE
    look_good_signal := 'clean';
  END IF;

  -- Combined:
  -- HIGH: either strong signal alone, OR two mild signals converge
  --       (Paulhus 2002 multi-indicator convergence principle)
  -- MODERATE: exactly one mild signal
  -- LOW: both signals clean or one clean + one silent
  IF fake_signal = 'high' OR look_good_signal = 'high' THEN
    distortion_out := 'high';
  ELSIF fake_signal = 'moderate' AND look_good_signal = 'moderate' THEN
    distortion_out := 'high';  -- convergence
  ELSIF fake_signal = 'moderate' OR look_good_signal = 'moderate' THEN
    distortion_out := 'moderate';
  ELSIF fake_signal = 'clean' OR look_good_signal = 'clean' THEN
    distortion_out := 'low';
  ELSE
    distortion_out := NULL;
  END IF;

  RETURN QUERY SELECT reliability_out, distortion_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.compute_newtworks_v1_bands(uuid, integer, integer) TO service_role, anon, authenticated;
