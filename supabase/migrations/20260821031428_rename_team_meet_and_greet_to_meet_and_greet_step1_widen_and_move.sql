-- Rename the stored pipeline stage value team_meet_and_greet -> meet_and_greet.
-- Peter directive 2026-08-20: the word "Team" was dropped from the stage, and
-- he wants the stored value to match the label rather than the two drifting.
--
-- STEP 1 of 2, deliberately split so nothing breaks in the gap between the
-- database changing and the deployed front end catching up (about 90 seconds).
-- This step accepts BOTH spellings, moves the rows, and updates the one
-- function that lists stages by name. Step 2 removes the old spelling once the
-- front end is live on the new one.

ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS team_assessments_status_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_status_check
  CHECK (
    status IS NULL OR status = ANY (ARRAY[
      'applied'::text, 'assessment_sent'::text, 'assessed'::text,
      'interview'::text, 'team_meet_and_greet'::text, 'meet_and_greet'::text,
      'offer'::text, 'reference_check'::text,
      'hired'::text, 'declined'::text, 'former'::text
    ])
  );

UPDATE public.hiring_candidates
SET status = 'meet_and_greet'
WHERE status = 'team_meet_and_greet';

CREATE OR REPLACE FUNCTION public.hiregauge_refresh_scoring_cache(p_agency_id uuid, p_scope text DEFAULT 'active'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_version bigint;
  v_count integer;
BEGIN
  INSERT INTO public.hiregauge_scoring_version (agency_id, version, updated_at)
  VALUES (p_agency_id, 1, now())
  ON CONFLICT (agency_id) DO NOTHING;

  SELECT version INTO v_version FROM public.hiregauge_scoring_version WHERE agency_id = p_agency_id;

  WITH targets AS (
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.assessment_completed_at IS NOT NULL
      AND (
        p_scope = 'all'
        OR hc.status IN ('applied','assessment_sent','assessed','interview','meet_and_greet','offer','reference_check')
      )
      AND hc.cached_scoring_version IS DISTINCT FROM v_version
  ),
  scored AS (
    SELECT v.id, v.assessment_composite, v.protocol_validity_v, v.protocol_validity_label
    FROM public.v_hiring_candidates v
    JOIN targets t ON t.id = v.id
  )
  UPDATE public.hiring_candidates hc
  SET cached_assessment_composite = s.assessment_composite,
      cached_protocol_validity_v = s.protocol_validity_v,
      cached_protocol_validity_label = s.protocol_validity_label,
      cached_scoring_version = v_version,
      cached_at = now()
  FROM scored s
  WHERE hc.id = s.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
