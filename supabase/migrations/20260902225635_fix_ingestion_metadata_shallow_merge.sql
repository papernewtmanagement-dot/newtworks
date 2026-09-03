-- jsonb || jsonb is a SHALLOW merge: a nested object on the right replaces the whole
-- nested object on the left, so a writer that only knows some fields nulls out the rest.
-- This merges recursively and never lets an incoming null clobber an existing value.
create or replace function public.jsonb_merge_preserve(p_existing jsonb, p_incoming jsonb)
returns jsonb
language plpgsql
immutable
as $function$
declare
  v_result jsonb;
  v_key    text;
  v_inc    jsonb;
  v_exi    jsonb;
begin
  if p_existing is null or jsonb_typeof(p_existing) <> 'object' then
    return p_incoming;
  end if;
  if p_incoming is null or jsonb_typeof(p_incoming) <> 'object' then
    return p_existing;
  end if;

  v_result := p_existing;

  for v_key in select jsonb_object_keys(p_incoming) loop
    v_inc := p_incoming -> v_key;
    v_exi := p_existing -> v_key;

    if jsonb_typeof(v_inc) = 'object' and jsonb_typeof(v_exi) = 'object' then
      v_result := jsonb_set(v_result, array[v_key],
                            public.jsonb_merge_preserve(v_exi, v_inc), true);
    elsif v_inc is null or jsonb_typeof(v_inc) = 'null' then
      if v_exi is null then
        v_result := jsonb_set(v_result, array[v_key], 'null'::jsonb, true);
      end if;
    else
      v_result := jsonb_set(v_result, array[v_key], v_inc, true);
    end if;
  end loop;

  return v_result;
end;
$function$;

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

  -- Build new-shape ingestion_metadata from parser payload
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

  -- Layer 1: idempotency by gmail_message_id (new: via ingestion_metadata jsonb path)
  IF v_gmail_msg_id IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND ingestion_metadata->'source_message'->>'gmail_message_id' = v_gmail_msg_id
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
        first_name         = coalesce(first_name, v_first_name),
        last_name          = coalesce(last_name,  v_last_name),
        candidate_name     = coalesce(candidate_name, v_candidate_name),
        phone              = coalesce(phone, v_phone),
        position           = coalesce(position, v_position),
        applied_at         = coalesce(applied_at, v_applied_at),
        resume_url         = coalesce(resume_url, v_resume_url),
        resume_document_id = coalesce(resume_document_id, v_resume_doc_id),
        ingestion_metadata = public.jsonb_merge_preserve(coalesce(ingestion_metadata, '{}'::jsonb), v_ingestion),
        updated_at         = now()
      WHERE id = v_existing_id;

      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'updated_by_email'
      );
    END IF;
  END IF;

  -- Layer 1.5: dedup by (first_name, last_name, position) when no email/gmail_message_id
  -- is available to key off. Only matches candidates still in status='applied' - never
  -- silently folds a re-applicant into a row that already advanced (assessed/interview/
  -- hired/declined/former), since that could mask a genuine second application as an
  -- update to a closed decision.
  IF v_first_name IS NOT NULL AND v_last_name IS NOT NULL AND v_position IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(trim(first_name)) = lower(trim(v_first_name))
      AND lower(trim(last_name))  = lower(trim(v_last_name))
      AND position = v_position
      AND status = 'applied'
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.hiring_candidates
      SET
        email               = coalesce(email, v_email),
        phone               = coalesce(phone, v_phone),
        applied_at          = coalesce(applied_at, v_applied_at),
        resume_url          = coalesce(resume_url, v_resume_url),
        resume_document_id  = coalesce(resume_document_id, v_resume_doc_id),
        ingestion_metadata  = public.jsonb_merge_preserve(coalesce(ingestion_metadata, '{}'::jsonb), v_ingestion),
        updated_at          = now()
      WHERE id = v_existing_id;

      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'updated_by_name_position'
      );
    END IF;
  END IF;

  -- Layer 3: INSERT new candidate at status='applied'
  INSERT INTO public.hiring_candidates (
    agency_id, candidate_name, first_name, last_name,
    email, phone, position, status, status_updated_at, applied_at,
    resume_url, resume_document_id, ingestion_metadata
  ) VALUES (
    p_agency_id, v_candidate_name, v_first_name, v_last_name,
    v_email, v_phone, v_position, 'applied', v_applied_at, v_applied_at,
    v_resume_url, v_resume_doc_id, v_ingestion
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'assessment_id', v_existing_id,
    'action', 'inserted'
  );
END;
$function$;
