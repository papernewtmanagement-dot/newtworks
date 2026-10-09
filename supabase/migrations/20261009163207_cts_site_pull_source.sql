-- CTS site pull (2026-10-09): results read straight off app.ctssalesprofile.com
-- by document-processor mode cts_site, no AI. New source value 'cts_site'.
-- record_cts_result stays the only writer; only its allowed-source list changes.
ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS hiring_candidates_cts_source_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_cts_source_check
  CHECK (cts_source IS NULL OR cts_source = ANY (ARRAY['drive_pdf'::text, 'manual'::text, 'cts_site'::text]));

CREATE OR REPLACE FUNCTION public.record_cts_result(p_candidate_id uuid, p_payload jsonb, p_source text DEFAULT 'manual'::text, p_recorded_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing timestamptz;
  v_name     text;
  v_traits   integer;
BEGIN
  PERFORM public.require_login('admin');
  IF p_source NOT IN ('drive_pdf','manual','cts_site') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'source must be drive_pdf, manual or cts_site');
  END IF;

  -- The vendor's overall score is never stored (Peter, 2026-09-26).
  p_payload := p_payload - 'cts_score';

  SELECT cts_completed_at, candidate_name INTO v_existing, v_name
  FROM public.hiring_candidates WHERE id = p_candidate_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'candidate not found');
  END IF;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'action', 'skipped',
      'reason', 'a CTS result is already on this candidate',
      'recorded_at', v_existing);
  END IF;

  SELECT count(*) INTO v_traits
  FROM jsonb_each(COALESCE(p_payload->'primary_traits', '{}'::jsonb)) AS t(k, v)
  WHERE jsonb_typeof(v) = 'number';

  IF v_traits < 7 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('payload carries %s of 9 primary trait scores, refusing to record a partial result', v_traits));
  END IF;

  UPDATE public.hiring_candidates
  SET cts_result       = p_payload,
      cts_source       = p_source,
      cts_recorded_by  = p_recorded_by,
      cts_completed_at = NOW()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('ok', true, 'action', 'recorded',
    'candidate_id', p_candidate_id, 'name', v_name,
    'primary_traits_recorded', v_traits);
END;
$function$;
