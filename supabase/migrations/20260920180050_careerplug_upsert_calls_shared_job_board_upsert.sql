-- One copy of the candidate fill step.
--
-- upsert_candidate_from_careerplug carried its own duplicate of the
-- find-then-fill-then-insert tail. upsert_candidate_from_job_board already did
-- the same job for the Indeed, ZipRecruiter and careers-page paths. This points
-- the CareerPlug path at the shared function so there is one copy to maintain.
--
-- upsert_candidate_from_careerplug keeps its signature, its Gmail message-id
-- idempotency check, and its return key name (assessment_id). Callers see no
-- change.
--
-- Six behaviors moved into the shared function so nothing regressed:
--   1. careerplug_applicant_id passed to find_existing_candidate (match layer 1)
--   2. resume_document_id written
--   3. phone normalised to ten digits on write
--   4. email lowercased on write
--   5. candidate_name falls back to a supplied full name, then the email
--   6. applied_at cast guarded, degrades to now() instead of raising
-- Items 3 and 4 also fix the three job-board paths, which were storing raw
-- phone and mixed-case email. Matching was never affected; it normalises
-- independently.
--
-- Also now writes careerplug_app_id on the candidate row. find_existing_candidate
-- matches on that column as its strongest key, but no ingest path had ever
-- populated it.

CREATE OR REPLACE FUNCTION public.upsert_candidate_from_job_board(p_agency_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_first    text  := nullif(trim(p_payload->>'first_name'), '');
  v_last     text  := nullif(trim(p_payload->>'last_name'), '');
  v_email    text  := lower(nullif(trim(p_payload->>'email'), ''));
  v_phone    text  := nullif(trim(p_payload->>'phone'), '');
  v_resume   text  := nullif(trim(p_payload->>'resume_url'), '');
  v_position text  := nullif(trim(p_payload->>'position'), '');
  v_channel  text  := nullif(trim(p_payload->>'source_channel'), '');
  v_app      text  := nullif(trim(p_payload->>'careerplug_applicant_id'), '');
  v_meta     jsonb := coalesce(p_payload->'ingestion_metadata', '{}'::jsonb);
  v_posting  uuid;
  v_doc      uuid;
  v_applied  timestamptz;
  v_name     text;
  v_id       uuid;
BEGIN
  IF p_agency_id IS NULL THEN
    RETURN jsonb_build_object('candidate_id', NULL, 'action', 'skipped_no_agency');
  END IF;

  -- Never let a row land with a blank name when only one part arrived.
  v_name := nullif(trim(concat_ws(' ', v_first, v_last)), '');
  IF v_name IS NULL THEN
    v_name := coalesce(nullif(trim(p_payload->>'candidate_name'), ''), v_email);
  END IF;

  -- Casts are guarded. A malformed value from a job board degrades to a null
  -- field instead of taking the whole application down.
  BEGIN
    v_applied := nullif(trim(p_payload->>'applied_at'), '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_applied := NULL;
  END;
  IF v_applied IS NULL THEN
    v_applied := now();
  END IF;

  BEGIN
    v_posting := nullif(trim(p_payload->>'job_posting_id'), '')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_posting := NULL;
  END;

  BEGIN
    v_doc := nullif(trim(p_payload->>'resume_document_id'), '')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_doc := NULL;
  END;

  v_id := public.find_existing_candidate(
    p_agency_id         => p_agency_id,
    p_email             => v_email,
    p_phone             => v_phone,
    p_first_name        => v_first,
    p_last_name         => v_last,
    p_position          => v_position,
    p_careerplug_app_id => v_app
  );

  IF v_id IS NOT NULL THEN
    UPDATE public.hiring_candidates
    SET first_name         = coalesce(first_name, v_first),
        last_name          = coalesce(last_name, v_last),
        candidate_name     = coalesce(candidate_name, v_name),
        email              = coalesce(email, v_email),
        phone              = coalesce(phone, public.normalise_us_phone(v_phone)),
        position           = coalesce(position, v_position),
        job_posting_id     = coalesce(job_posting_id, v_posting),
        resume_url         = coalesce(resume_url, v_resume),
        resume_document_id = coalesce(resume_document_id, v_doc),
        careerplug_app_id  = coalesce(careerplug_app_id, v_app),
        source_channel     = coalesce(source_channel, v_channel),
        applied_at         = least(coalesce(applied_at, v_applied), v_applied),
        ingestion_metadata = public.jsonb_merge_preserve(coalesce(ingestion_metadata, '{}'::jsonb), v_meta),
        updated_at         = now()
    WHERE id = v_id;

    RETURN jsonb_build_object('candidate_id', v_id, 'action', 'matched_existing_candidate');
  END IF;

  INSERT INTO public.hiring_candidates (
    agency_id, first_name, last_name, candidate_name, email, phone,
    position, job_posting_id, resume_url, resume_document_id, careerplug_app_id,
    status, status_updated_at, applied_at, source_channel, ingestion_metadata
  ) VALUES (
    p_agency_id, v_first, v_last, v_name, v_email, public.normalise_us_phone(v_phone),
    v_position, v_posting, v_resume, v_doc, v_app,
    'applied', v_applied, v_applied, v_channel, v_meta
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('candidate_id', v_id, 'action', 'inserted');
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_candidate_from_careerplug(p_agency_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_id    uuid;
  v_email          text := lower(nullif(p_payload->>'email',''));
  v_gmail_msg_id   text := nullif(p_payload->>'gmail_message_id','');
  v_first_name     text := nullif(p_payload->>'first_name','');
  v_last_name      text := nullif(p_payload->>'last_name','');
  v_candidate_name text;
  v_phone          text := nullif(p_payload->>'phone','');
  v_position       text := nullif(p_payload->>'position','');
  v_applied_at     timestamptz;
  v_resume_url     text := nullif(p_payload->>'resume_url','');
  v_resume_doc_id  uuid;
  v_meta           jsonb := coalesce(p_payload->'careerplug_metadata','{}'::jsonb);
  v_ingestion      jsonb;
  v_result         jsonb;
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

  -- Layer 1: message-level idempotency. Not person matching — it stops the same
  -- email attachment being processed twice. Stays here because it is specific to
  -- the emailed-resume path and means nothing to a job board.
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

  -- Layers 2 and 3: person matching, then fill-or-insert. One shared copy with
  -- the Indeed, ZipRecruiter and careers-page paths.
  v_result := public.upsert_candidate_from_job_board(
    p_agency_id,
    jsonb_build_object(
      'first_name',              v_first_name,
      'last_name',               v_last_name,
      'candidate_name',          v_candidate_name,
      'email',                   v_email,
      'phone',                   v_phone,
      'position',                v_position,
      'applied_at',              v_applied_at,
      'resume_url',              v_resume_url,
      'resume_document_id',      v_resume_doc_id,
      'careerplug_applicant_id', nullif(v_meta->>'careerplug_applicant_id',''),
      'ingestion_metadata',      v_ingestion
    )
  );

  -- Callers read assessment_id. Keep that name.
  RETURN jsonb_build_object(
    'assessment_id', v_result->>'candidate_id',
    'action',        v_result->>'action'
  );
END;
$function$;
