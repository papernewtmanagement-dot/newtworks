-- One function, one job: decide whether an incoming applicant already has a row.
-- Peter directive 2026-09-18: every function that is about to create a candidate row
-- must check first. A match on CareerPlug application id, phone, email, address, or
-- full name means the same person.
--
-- Both ingest paths previously carried their own inline, DIFFERENT match logic, and
-- neither checked the phone number. That is what produced the duplicate rows for
-- Sean O'Neal, Gamliela Tolbert, Rebecca Johnson and Nishu Dandyan in September 2026:
-- the CareerPlug webhook row and the emailed-resume row carried different email
-- addresses but identical phone numbers. Phone alone would have caught all four.
--
-- TERMINAL STATUSES ARE EXCLUDED ON PURPOSE. Someone who was declined, left the
-- agency, or was hired and later applies again is a genuine new application and gets
-- a fresh row. Folding a re-applicant into a closed decision would silently deny them
-- an assessment (see Reno Avila, two rows, August 2026).
CREATE OR REPLACE FUNCTION public.find_existing_candidate(
  p_agency_id         uuid,
  p_email             text DEFAULT NULL,
  p_phone             text DEFAULT NULL,
  p_first_name        text DEFAULT NULL,
  p_last_name         text DEFAULT NULL,
  p_position          text DEFAULT NULL,
  p_careerplug_app_id text DEFAULT NULL,
  p_address_line1     text DEFAULT NULL,
  p_zip_code          text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id     uuid;
  v_email  text := lower(nullif(trim(p_email), ''));
  v_phone  text := public.normalise_us_phone(nullif(trim(p_phone), ''));
  v_first  text := lower(nullif(trim(p_first_name), ''));
  v_last   text := lower(nullif(trim(p_last_name), ''));
  v_pos    text := nullif(trim(p_position), '');
  v_addr   text := lower(nullif(trim(p_address_line1), ''));
  v_zip    text := nullif(regexp_replace(coalesce(p_zip_code, ''), '[^0-9]', '', 'g'), '');
  v_app    text := nullif(trim(p_careerplug_app_id), '');
BEGIN
  IF p_agency_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Layer 1: CareerPlug application id. Exact, unique, strongest key there is.
  IF v_app IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id AND careerplug_app_id = v_app
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Layer 2: email address.
  IF v_email IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(trim(email)) = v_email
      AND status NOT IN ('declined', 'former', 'hired')
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Layer 3: phone number, compared as ten digits so formatting never blocks a match.
  IF v_phone IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND public.normalise_us_phone(phone) = v_phone
      AND status NOT IN ('declined', 'former', 'hired')
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Layer 4: street address plus postcode.
  IF v_addr IS NOT NULL AND v_zip IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(trim(address_line1)) = v_addr
      AND regexp_replace(coalesce(zip_code, ''), '[^0-9]', '', 'g') = v_zip
      AND status NOT IN ('declined', 'former', 'hired')
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Layer 5: full name.
  IF v_first IS NOT NULL AND v_last IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(trim(first_name)) = v_first
      AND lower(trim(last_name))  = v_last
      AND status NOT IN ('declined', 'former', 'hired')
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  -- Layer 6: last name plus the exact role applied for, for rows where the first name
  -- is recorded differently between sources (Nishu D against Nishu Dandyan).
  IF v_last IS NOT NULL AND v_pos IS NOT NULL THEN
    SELECT id INTO v_id FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(trim(last_name)) = v_last
      AND position = v_pos
      AND status NOT IN ('declined', 'former', 'hired')
    ORDER BY created_at LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.find_existing_candidate(uuid,text,text,text,text,text,text,text,text) IS
'Single source of truth for "does this applicant already have a row?". Every path that creates a hiring_candidates row calls this first. Matches on CareerPlug application id, email, phone (ten digits), address plus postcode, full name, or last name plus role. Skips declined, former and hired rows so a genuine re-application is not folded into a closed decision. Peter directive 2026-09-18.';
