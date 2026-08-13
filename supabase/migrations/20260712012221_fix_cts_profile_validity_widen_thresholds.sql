-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 01:22:21 UTC (ledger name: fix_cts_profile_validity_widen_thresholds) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712012221.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.cts_profile_validity(p_assessment_id uuid)
 RETURNS TABLE(validity_status text, reliability text, response_distortion text, warning text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  r text;
  d text;
BEGIN
  SELECT ta.reliability, ta.response_distortion INTO r, d
  FROM public.team_assessments ta
  WHERE ta.id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  RETURN QUERY SELECT
    CASE
      WHEN r IN ('high','very_high') AND d IN ('low','very_low') THEN 'valid'
      WHEN r IS NULL OR d IS NULL THEN 'unknown'
      ELSE 'questionable'
    END,
    r,
    d,
    CASE
      WHEN r IS NULL AND d IS NULL THEN 'Validity metrics not recorded for this assessment.'
      WHEN r = 'low' THEN 'LOW reliability — profile may be internally inconsistent. Interpret scores with caution.'
      WHEN r = 'moderate' THEN 'MODERATE reliability — profile is somewhat inconsistent. Consider retest.'
      WHEN d = 'moderate' THEN 'ELEVATED response distortion — candidate may have been gaming the assessment. Scores should not be treated as face-valid.'
      WHEN d = 'high' OR d = 'very_high' THEN 'HIGH response distortion — profile is very likely gamed. Do not treat scores as face-valid.'
      ELSE NULL
    END;
END;
$function$;
