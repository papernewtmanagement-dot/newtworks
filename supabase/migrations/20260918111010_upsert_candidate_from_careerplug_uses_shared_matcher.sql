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
  v_ingestion        jsonb;
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

  v_ingestion := jsonb_build_object(
    'source',       'careerplug',
    'ingested_at',  now(),
    'careerplug',   jsonb_build_object(
      'raw_line',                v_meta->>'raw_line',
      'is_fast_track',           (nullif(v_meta->>'is_fast_track',''))::boolean,
      'prescreen_score',         (nullif(v_meta->>'prescreen_score',''))::int,
      'source_platform',         v_meta->>'source_platform',
      'careerplug_applicant_id', v_meta->>'careerplug_applicant_id'
    ),
    'source_message', jsonb_build_object(
      'gmail_from',       v_meta->>'gmail_from',
      'gmail_subject',    v_meta->>'gmail_subject',
      'gmail_message_id', v_gmail_msg_id
    )
  );

  -- Layer 1: message-level idempotency. This is not person matching — it stops the
  -- same email attachment being processed twice.
  IF v_gmail_msg_id IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND ingestion_metadata->'source_message'->>'gmail_message_id' = v_gmail_msg_id
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      RETURN jsonb_build_object('assessment_id', v_existing_id, 'action', 'noop_by_gmail_message_id');
    END IF;
  END IF;

  -- Layer 2: does this person already have a row? All matching logic lives in
  -- find_existing_candidate so both ingest paths behave identically. Rewritten
  -- 2026-09-18 — the old inline version matched on email, or on first name plus last
  -- name plus role, and never on phone. Emailed resumes arrive with no role and often
  -- a different email address than the application form, so every forwarded resume
  -- created a second row for someone already in the table.
  v_existing_id := public.find_existing_candidate(
    p_agency_id         => p_agency_id,
    p_email             => v_email,
    p_phone             => v_phone,
    p_first_name        => v_first_name,
    p_last_name         => v_last_name,
    p_position          => v_position,
    p_careerplug_app_id => nullif(v_meta->>'careerplug_applicant_id','')
  );

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.hiring_candidates
    SET
      first_name         = coalesce(first_name, v_first_name),
      last_name          = coalesce(last_name,  v_last_name),
      candidate_name     = coalesce(candidate_name, v_candidate_name),
      email              = coalesce(email, v_email),
      phone              = coalesce(phone, public.normalise_us_phone(v_phone)),
      position           = coalesce(position, v_position),
      applied_at         = least(coalesce(applied_at, v_applied_at), v_applied_at),
      resume_url         = coalesce(resume_url, v_resume_url),
      resume_document_id = coalesce(resume_document_id, v_resume_doc_id),
      ingestion_metadata = public.jsonb_merge_preserve(coalesce(ingestion_metadata, '{}'::jsonb), v_ingestion),
      updated_at         = now()
    WHERE id = v_existing_id;

    RETURN jsonb_build_object('assessment_id', v_existing_id, 'action', 'matched_existing_candidate');
  END IF;

  -- Layer 3: genuinely new person.
  INSERT INTO public.hiring_candidates (
    agency_id, candidate_name, first_name, last_name,
    email, phone, position, status, status_updated_at, applied_at,
    resume_url, resume_document_id, ingestion_metadata
  ) VALUES (
    p_agency_id, v_candidate_name, v_first_name, v_last_name,
    v_email, public.normalise_us_phone(v_phone), v_position, 'applied', v_applied_at, v_applied_at,
    v_resume_url, v_resume_doc_id, v_ingestion
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object('assessment_id', v_existing_id, 'action', 'inserted');
END;
$function$;
