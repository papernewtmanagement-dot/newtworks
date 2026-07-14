-- 2026-07-13: idempotent CareerPlug applicant upsert.
-- Called by document-processor mode=careerplug after parsing.
-- Layered dedup: (1) gmail_message_id (2) lower(email) (3) INSERT new.

CREATE OR REPLACE FUNCTION public.upsert_candidate_from_careerplug(
  p_agency_id uuid,
  p_payload   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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
    FROM public.team_assessments
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
    FROM public.team_assessments
    WHERE agency_id = p_agency_id
      AND lower(email) = v_email
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.team_assessments
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

  -- Layer 3: INSERT new candidate at status='applied'
  INSERT INTO public.team_assessments (
    agency_id, assessment_date, candidate_name,
    first_name, last_name, email, phone, position,
    status, status_updated_at, applied_at,
    resume_url, resume_document_id,
    source_gmail_message_id, candidate_source,
    careerplug_metadata, notes
  ) VALUES (
    p_agency_id, v_applied_at::date, v_candidate_name,
    v_first_name, v_last_name, v_email, v_phone, v_position,
    'applied', v_applied_at, v_applied_at,
    v_resume_url, v_resume_doc_id,
    v_gmail_msg_id, 'careerplug',
    v_meta,
    concat_ws(E'\n',
      '=== APPLIED via CareerPlug (' || to_char(v_applied_at, 'YYYY-MM-DD HH24:MI TZ') || ') ===',
      CASE WHEN v_meta ? 'source_platform'
           THEN 'Source platform: ' || (v_meta->>'source_platform') END,
      CASE WHEN v_meta ? 'is_fast_track' AND (v_meta->>'is_fast_track')::boolean
           THEN 'FAST TRACK applicant (matched priority prescreen answer)' END
    )
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'assessment_id', v_existing_id,
    'action', 'inserted'
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.upsert_candidate_from_careerplug(uuid, jsonb) TO authenticated, service_role;
