-- upsert_candidate_from_job_board — one entry point for job-board apply webhooks
-- and the careers page to create a hiring_candidates row.
--
-- Why this exists: indeed-apply-webhook, zip-apply-webhook and careers-site each
-- inserted straight into hiring_candidates with no duplicate check at all. Rather
-- than copy a find-then-fill block into three TypeScript files (three copies that
-- would drift), the whole job lives here and each edge function makes one RPC call.
--
-- Matching is NOT done here. It is delegated to find_existing_candidate, which is
-- the single matcher for the whole system.
--
-- Fill rule on a matched row: coalesce only. An existing value is never overwritten,
-- status is never reset, and applied_at keeps the earliest date seen.

CREATE OR REPLACE FUNCTION public.upsert_candidate_from_job_board(
  p_agency_id uuid,
  p_payload   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_first    text        := nullif(trim(p_payload->>'first_name'), '');
  v_last     text        := nullif(trim(p_payload->>'last_name'), '');
  v_email    text        := nullif(trim(p_payload->>'email'), '');
  v_phone    text        := nullif(trim(p_payload->>'phone'), '');
  v_resume   text        := nullif(trim(p_payload->>'resume_url'), '');
  v_position text        := nullif(trim(p_payload->>'position'), '');
  v_posting  uuid        := nullif(trim(p_payload->>'job_posting_id'), '')::uuid;
  v_channel  text        := nullif(trim(p_payload->>'source_channel'), '');
  v_meta     jsonb       := coalesce(p_payload->'ingestion_metadata', '{}'::jsonb);
  v_applied  timestamptz := coalesce(nullif(trim(p_payload->>'applied_at'), '')::timestamptz, now());
  v_name     text        := nullif(trim(concat_ws(' ', v_first, v_last)), '');
  v_id       uuid;
BEGIN
  IF p_agency_id IS NULL THEN
    RETURN jsonb_build_object('candidate_id', NULL, 'action', 'skipped_no_agency');
  END IF;

  v_id := public.find_existing_candidate(
    p_agency_id  => p_agency_id,
    p_email      => v_email,
    p_phone      => v_phone,
    p_first_name => v_first,
    p_last_name  => v_last,
    p_position   => v_position
  );

  IF v_id IS NOT NULL THEN
    UPDATE public.hiring_candidates
    SET first_name         = coalesce(first_name, v_first),
        last_name          = coalesce(last_name, v_last),
        candidate_name     = coalesce(candidate_name, v_name),
        email              = coalesce(email, v_email),
        phone              = coalesce(phone, v_phone),
        position           = coalesce(position, v_position),
        job_posting_id     = coalesce(job_posting_id, v_posting),
        resume_url         = coalesce(resume_url, v_resume),
        source_channel     = coalesce(source_channel, v_channel),
        applied_at         = least(coalesce(applied_at, v_applied), v_applied),
        ingestion_metadata = public.jsonb_merge_preserve(coalesce(ingestion_metadata, '{}'::jsonb), v_meta),
        updated_at         = now()
    WHERE id = v_id;

    RETURN jsonb_build_object('candidate_id', v_id, 'action', 'matched_existing_candidate');
  END IF;

  INSERT INTO public.hiring_candidates (
    agency_id, first_name, last_name, candidate_name, email, phone,
    position, job_posting_id, resume_url, status, status_updated_at,
    applied_at, source_channel, ingestion_metadata
  ) VALUES (
    p_agency_id, v_first, v_last, v_name, v_email, v_phone,
    v_position, v_posting, v_resume, 'applied', v_applied,
    v_applied, v_channel, v_meta
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('candidate_id', v_id, 'action', 'inserted');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upsert_candidate_from_job_board(uuid, jsonb) TO service_role;
