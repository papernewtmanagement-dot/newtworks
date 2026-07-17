-- Drop the ═══ APPLIED via CareerPlug ═══ marker from the notes column on
-- new INSERTs. Every fact it encoded is already stored in first-class columns
-- set in the same INSERT (candidate_source, applied_at, careerplug_metadata).
-- Notes should be for human observations, not ingestion breadcrumbs.
-- Signature (uuid, jsonb) unchanged — no overload risk. Companion cleanup of
-- 12 existing rows carrying the pure-marker notes body ran 2026-07-17 evening
-- (Peter-authorized per open_question a1be9250).
CREATE OR REPLACE FUNCTION public.upsert_candidate_from_careerplug(p_agency_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_id      uuid;
  v_email            text := lower(nullif(p_payload->>'email',''));
  v_gmail_msg_id     text := nullif(p_payload->>'gmail_message_id','');
  v_first_name       text := nullif(p_payload->>'first_name','');
  v_last_name        text := nullif(p_payload->>'last_name','');
  v_candidate_name   text;
  v_phone            text := nullif(p_payload->>'phone','');
  v_position         text := nullif(p_payload->>'position','');
  v_applied_at       timestamptz;
  v_resume_url       text := nullif(p_payload->>'resume_url','');
  v_resume_doc_id    uuid;
  v_meta             jsonb := coalesce(p_payload->'careerplug_metadata','{}'::jsonb);
BEGIN
  v_candidate_name := trim(concat_ws(' ', v_first_name, v_last_name));
  IF v_candidate_name = '' THEN
    v_candidate_name := coalesce(nullif(p_payload->>'candidate_name',''), v_email);
  END IF;

  BEGIN
    v_applied_at := (p_payload->>'applied_at')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_applied_at := now();
  END;
  IF v_applied_at IS NULL THEN
    v_applied_at := now();
  END IF;

  BEGIN
    v_resume_doc_id := nullif(p_payload->>'resume_document_id','')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_resume_doc_id := NULL;
  END;

  -- Layer 1: idempotency by gmail_message_id
  IF v_gmail_msg_id IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND source_gmail_message_id = v_gmail_msg_id
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'noop_by_gmail_message_id'
      );
    END IF;
  END IF;

  -- Layer 2: dedup by email
  IF v_email IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(email) = v_email
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.hiring_candidates
      SET
        first_name             = coalesce(first_name, v_first_name),
        last_name              = coalesce(last_name,  v_last_name),
        candidate_name         = coalesce(candidate_name, v_candidate_name),
        phone                  = coalesce(phone, v_phone),
        position               = coalesce(position, v_position),
        applied_at             = coalesce(applied_at, v_applied_at),
        resume_url             = coalesce(resume_url, v_resume_url),
        resume_document_id     = coalesce(resume_document_id, v_resume_doc_id),
        source_gmail_message_id= coalesce(source_gmail_message_id, v_gmail_msg_id),
        candidate_source       = coalesce(candidate_source, 'careerplug'),
        careerplug_metadata    = coalesce(careerplug_metadata, '{}'::jsonb) || v_meta,
        updated_at             = now()
      WHERE id = v_existing_id;

      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'updated_by_email'
      );
    END IF;
  END IF;

  -- Layer 3: INSERT new candidate at status='applied'. notes intentionally
  -- left NULL — ingestion facts live in candidate_source / applied_at /
  -- careerplug_metadata. notes is reserved for human observations.
  INSERT INTO public.hiring_candidates (
    agency_id,
    assessment_date,
    candidate_name,
    first_name,
    last_name,
    email,
    phone,
    position,
    status,
    status_updated_at,
    applied_at,
    resume_url,
    resume_document_id,
    source_gmail_message_id,
    candidate_source,
    careerplug_metadata
  ) VALUES (
    p_agency_id,
    v_applied_at::date,
    v_candidate_name,
    v_first_name,
    v_last_name,
    v_email,
    v_phone,
    v_position,
    'applied',
    v_applied_at,
    v_applied_at,
    v_resume_url,
    v_resume_doc_id,
    v_gmail_msg_id,
    'careerplug',
    v_meta
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'assessment_id', v_existing_id,
    'action', 'inserted'
  );
END;
$function$;
