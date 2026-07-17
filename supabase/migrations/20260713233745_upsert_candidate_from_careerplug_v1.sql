-- Idempotent upsert for CareerPlug applicant notifications.
--
-- Called by document-processor after parsing a CareerPlug notification email.
-- Idempotency layers, in order:
--   1) source_gmail_message_id — same email reprocessed: return existing row, no-op writes.
--   2) lower(email) match within agency — same person applying twice (e.g. Indeed + ZipRecruiter):
--      UPDATE selectively (never overwrite existing va_/fi_/rc_ scores, decisions, or notes).
--   3) Otherwise INSERT a new row at status='applied'.
--
-- Payload shape (jsonb):
--   {
--     "first_name": "Jane",
--     "last_name":  "Doe",
--     "email":      "jane@example.com",
--     "phone":      "5125551234",
--     "position":   "Sales Team Member",
--     "applied_at": "2026-07-13T15:00:00-05:00",   -- ISO 8601
--     "resume_url":       "https://.../resume.pdf",
--     "resume_document_id": "<uuid or null>",
--     "gmail_message_id": "19f...",
--     "careerplug_metadata": {                     -- pass-through for anything not first-class
--       "prescreen_score": 87,
--       "is_fast_track": true,
--       "source_platform": "Indeed",
--       "careerplug_applicant_id": "12345"
--     }
--   }
--
-- Returns jsonb: { assessment_id, action }
--   action = 'inserted' | 'updated_by_email' | 'noop_by_gmail_message_id'

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
  v_action           text;
BEGIN
  -- Build candidate_name for the identity_check constraint
  v_candidate_name := trim(concat_ws(' ', v_first_name, v_last_name));
  IF v_candidate_name = '' THEN
    v_candidate_name := coalesce(nullif(p_payload->>'candidate_name',''), v_email);
  END IF;

  -- Parse applied_at with fallback to now()
  BEGIN
    v_applied_at := (p_payload->>'applied_at')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_applied_at := now();
  END;
  IF v_applied_at IS NULL THEN
    v_applied_at := now();
  END IF;

  -- Parse resume_document_id if provided
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

  -- Layer 2: dedup by email (case-insensitive)
  IF v_email IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.team_assessments
    WHERE agency_id = p_agency_id
      AND lower(email) = v_email
    ORDER BY created_at ASC   -- oldest row is the canonical one; merge into it
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      -- UPDATE selectively: only fill empty fields, never overwrite Peter's work
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
        -- Merge metadata: existing wins for scalar keys; new keys added
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
    careerplug_metadata,
    assessment_type,
    notes
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
    v_meta,
    'other',                              -- CTS not yet complete; refined when Cheetah PDF arrives
    concat_ws(E'\n',
      '═══ APPLIED via CareerPlug (' || to_char(v_applied_at, 'YYYY-MM-DD HH24:MI TZ') || ') ═══',
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

-- Grant execute to authenticated + service_role (edge fns use service_role)
GRANT EXECUTE ON FUNCTION public.upsert_candidate_from_careerplug(uuid, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.upsert_candidate_from_careerplug(uuid, jsonb) IS
  'Idempotent applicant intake from CareerPlug notification emails. Called by document-processor after parsing. Dedup layers: gmail_message_id > email > insert new. Never overwrites existing va_/fi_/rc_/decision fields.';;