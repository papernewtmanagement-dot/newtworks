-- Backfill reliability + response_distortion for the six v1 candidates whose
-- assessments completed before compute_newtworks_v1_bands existed.
-- Excludes Marie Story (test) — her values were set manually and are locked.
UPDATE public.hiring_candidates hc
SET reliability = sub.reliability,
    response_distortion = sub.response_distortion,
    updated_at = NOW()
FROM (
  SELECT hc2.id,
         (compute_newtworks_v1_bands(hc2.id, NULL, 1)).reliability,
         (compute_newtworks_v1_bands(hc2.id, NULL, 1)).response_distortion
  FROM public.hiring_candidates hc2
  WHERE hc2.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND hc2.assessment_source = 'v1'
    AND hc2.id <> '97a56442-0be5-41f4-a2ba-c4b2f01f079a'  -- Marie Story (test) — manually set
) sub
WHERE hc.id = sub.id
  AND (sub.reliability IS NOT NULL OR sub.response_distortion IS NOT NULL);
