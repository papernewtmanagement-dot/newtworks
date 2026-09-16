-- =========================================================================
-- CTS Sales Profile: result storage + the single writer that records one.
-- =========================================================================
-- Peter ruling 2026-09-15 (option 2A): no CTS result on file, no interview
-- invite. This migration puts the result somewhere. The gate itself and the
-- PDF reader are separate pieces.
--
-- Shape taken from a real report (CTS Profile - Priscilla Brito - 20260714):
-- combined CTS+LSS score, CTS-only score, ego drive, empathy, coaching hours,
-- 9 primary traits, reliability, response distortion, LSS accuracy and speed
-- for math / verbal / problem solving, and 9 sales competencies.
--
-- The handful of numbers Peter sorts and filters on get their own columns.
-- The three blocks that are lists of named scores stay in one jsonb, because
-- thirty columns for a vendor report we do not control is a schema that
-- breaks the first time the vendor renames a trait.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cts_completed_at        timestamptz,
  ADD COLUMN IF NOT EXISTS cts_combined_score      numeric,
  ADD COLUMN IF NOT EXISTS cts_only_score          numeric,
  ADD COLUMN IF NOT EXISTS cts_ego_drive           numeric,
  ADD COLUMN IF NOT EXISTS cts_empathy             numeric,
  ADD COLUMN IF NOT EXISTS cts_coaching_hours      numeric,
  ADD COLUMN IF NOT EXISTS cts_reliability         text,
  ADD COLUMN IF NOT EXISTS cts_response_distortion text,
  ADD COLUMN IF NOT EXISTS cts_result              jsonb,
  ADD COLUMN IF NOT EXISTS cts_source              text,
  ADD COLUMN IF NOT EXISTS cts_recorded_by         text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_cts_reliability_check') THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_cts_reliability_check
      CHECK (cts_reliability IS NULL OR cts_reliability IN ('low','moderate','high'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_cts_distortion_check') THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_cts_distortion_check
      CHECK (cts_response_distortion IS NULL OR cts_response_distortion IN ('low','moderate','high'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_cts_source_check') THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_cts_source_check
      CHECK (cts_source IS NULL OR cts_source IN ('drive_pdf','manual'));
  END IF;
END $$;

COMMENT ON COLUMN public.hiring_candidates.cts_completed_at IS
  'When the CTS Sales Profile result was recorded on this candidate. Stamping this is what opens the interview gate — see trg_dispatch_cts_result.';
COMMENT ON COLUMN public.hiring_candidates.cts_result IS
  'Full CTS report: primary_traits, sales_competencies, lss (accuracy and speed per section), plus source_file and anything else the report carries. Vendor-shaped, deliberately not columns.';

-- -------------------------------------------------------------------------
-- record_cts_result — the ONLY writer of a CTS result.
-- -------------------------------------------------------------------------
-- Every path that records a result goes through here: the Drive PDF reader,
-- the candidate page, and any backfill. One function means the gate fires the
-- same way no matter where the result came from, and the shape of the payload
-- is checked in one place instead of three.
--
-- Idempotent on purpose. A candidate who already has a result keeps it and the
-- call reports skipped, so re-reading the same PDF cannot re-open the gate or
-- re-send an interview invite.
CREATE OR REPLACE FUNCTION public.record_cts_result(
  p_candidate_id uuid,
  p_payload      jsonb,
  p_source       text DEFAULT 'manual',
  p_recorded_by  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing timestamptz;
  v_name     text;
BEGIN
  IF p_source NOT IN ('drive_pdf','manual') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'source must be drive_pdf or manual');
  END IF;

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

  -- The combined score is the one figure the report leads with, so a payload
  -- without it is almost certainly a failed read rather than a real result.
  IF p_payload->>'combined_score' IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'payload has no combined_score, refusing to record a partial result');
  END IF;

  UPDATE public.hiring_candidates
  SET cts_combined_score      = (p_payload->>'combined_score')::numeric,
      cts_only_score          = NULLIF(p_payload->>'cts_score','')::numeric,
      cts_ego_drive           = NULLIF(p_payload->>'ego_drive','')::numeric,
      cts_empathy             = NULLIF(p_payload->>'empathy','')::numeric,
      cts_coaching_hours      = NULLIF(p_payload->>'coaching_hours','')::numeric,
      cts_reliability         = lower(NULLIF(p_payload->>'reliability','')),
      cts_response_distortion = lower(NULLIF(p_payload->>'response_distortion','')),
      cts_result              = p_payload,
      cts_source              = p_source,
      cts_recorded_by         = p_recorded_by,
      cts_completed_at        = NOW()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('ok', true, 'action', 'recorded',
    'candidate_id', p_candidate_id, 'name', v_name,
    'combined_score', (p_payload->>'combined_score')::numeric);
END;
$function$;

COMMENT ON FUNCTION public.record_cts_result(uuid, jsonb, text, text) IS
  'Single writer for a CTS Sales Profile result. Idempotent: a candidate who already has one is skipped. Stamping cts_completed_at is what fires the interview gate.';
