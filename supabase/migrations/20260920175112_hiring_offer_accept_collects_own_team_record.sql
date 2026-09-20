-- The acceptance page now confirms the details that came off a resume, and
-- accepting builds the team row. Everything the new hire is not allowed to
-- set is simply absent from the insert, so the form cannot reach it.

CREATE OR REPLACE FUNCTION public.hiring_offer_accept_view(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE c record; v_asked int;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT id, agency_id, first_name, last_name, candidate_name, nickname,
         email, phone, offer_job_title, position,
         offer_letter_body, offer_start_date, offer_respond_by, offer_reports_to,
         offer_accept_expires_at, offer_accepted_at
  INTO c
  FROM public.hiring_candidates
  WHERE offer_accept_token = p_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT COALESCE(NULLIF(setting_value,'')::int, 3) INTO v_asked
  FROM public.settings
  WHERE agency_id = c.agency_id AND setting_key = 'onboarding_reference_requested';
  v_asked := COALESCE(v_asked, 3);

  RETURN jsonb_build_object(
    'ok', true,
    'expired',     COALESCE(c.offer_accept_expires_at < now(), false),
    'accepted',    c.offer_accepted_at IS NOT NULL,
    'first_name',  COALESCE(NULLIF(c.first_name,''), split_part(COALESCE(c.candidate_name,''), ' ', 1), 'there'),
    'full_name',   COALESCE(NULLIF(c.candidate_name,''), c.first_name),
    -- Prefilled so the new hire only has to correct what is wrong. These came
    -- off a resume and are often out of date.
    'prefill_first_name', COALESCE(NULLIF(c.first_name,''), split_part(COALESCE(c.candidate_name,''), ' ', 1), ''),
    'prefill_last_name',  COALESCE(NULLIF(c.last_name,''), split_part(COALESCE(c.candidate_name,''), ' ', 2), ''),
    'prefill_nickname',   COALESCE(c.nickname, ''),
    'prefill_email',      COALESCE(c.email, ''),
    'prefill_phone',      COALESCE(c.phone, ''),
    'job_title',   COALESCE(c.offer_job_title, c.position),
    'reports_to',  c.offer_reports_to,
    'start_date',  c.offer_start_date,
    'respond_by',  c.offer_respond_by,
    'letter_body', c.offer_letter_body,
    'references_wanted', v_asked
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.hiring_accept_offer(p_token text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c          record;
  v_asked    int;
  v_refs     jsonb;
  v_ref      jsonb;
  v_ssn      text;
  v_dob      date;
  v_name     text;
  v_first    text;
  v_last     text;
  v_nick     text;
  v_email    text;
  v_phone    text;
  v_digits   text;
  v_team     uuid;
  v_n        int := 0;
BEGIN
  IF p_token IS NULL OR btrim(p_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT id, agency_id, candidate_name, first_name, last_name,
         offer_accept_expires_at, offer_accepted_at
  INTO c
  FROM public.hiring_candidates
  WHERE offer_accept_token = p_token
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF c.offer_accepted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_accepted');
  END IF;
  IF COALESCE(c.offer_accept_expires_at < now(), false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'expired');
  END IF;

  SELECT COALESCE(NULLIF(setting_value,'')::int, 3) INTO v_asked
  FROM public.settings
  WHERE agency_id = c.agency_id AND setting_key = 'onboarding_reference_requested';
  v_asked := COALESCE(v_asked, 3);

  -- ---- what must be there -------------------------------------------------
  v_name := btrim(COALESCE(p_payload ->> 'signed_name', ''));
  IF v_name = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_signature');
  END IF;

  v_first := btrim(COALESCE(p_payload ->> 'first_name', ''));
  v_last  := btrim(COALESCE(p_payload ->> 'last_name', ''));
  IF v_first = '' OR v_last = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_name');
  END IF;
  v_nick := NULLIF(btrim(COALESCE(p_payload ->> 'nickname', '')), '');

  v_email := lower(btrim(COALESCE(p_payload ->> 'email_personal', '')));
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_email');
  END IF;

  v_phone  := btrim(COALESCE(p_payload ->> 'phone_personal', ''));
  v_digits := regexp_replace(v_phone, '[^0-9]', '', 'g');
  IF length(v_digits) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_phone');
  END IF;

  BEGIN
    v_dob := (p_payload ->> 'date_of_birth')::date;
  EXCEPTION WHEN others THEN
    v_dob := NULL;
  END;
  IF v_dob IS NULL OR v_dob > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_date_of_birth');
  END IF;

  IF btrim(COALESCE(p_payload ->> 'address_line1','')) = ''
     OR btrim(COALESCE(p_payload ->> 'city','')) = ''
     OR btrim(COALESCE(p_payload ->> 'state','')) = ''
     OR btrim(COALESCE(p_payload ->> 'zip_code','')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_address');
  END IF;

  v_ssn := regexp_replace(COALESCE(p_payload ->> 'ssn',''), '[^0-9]', '', 'g');
  IF length(v_ssn) <> 9 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_ssn');
  END IF;

  v_refs := COALESCE(p_payload -> 'references', '[]'::jsonb);
  IF jsonb_typeof(v_refs) <> 'array' OR jsonb_array_length(v_refs) < v_asked THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_references',
                              'references_wanted', v_asked);
  END IF;

  FOR v_ref IN SELECT * FROM jsonb_array_elements(v_refs) LOOP
    IF btrim(COALESCE(v_ref ->> 'contact_name','')) = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'reference_needs_name');
    END IF;
    IF btrim(COALESCE(v_ref ->> 'phone','')) = ''
       AND btrim(COALESCE(v_ref ->> 'email','')) = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'reference_needs_contact');
    END IF;
  END LOOP;

  -- ---- write it -----------------------------------------------------------
  UPDATE public.hiring_candidates
  SET offer_accepted_at          = now(),
      offer_accept_signed_name   = v_name,
      offer_accept_token         = NULL,          -- the link dies here
      first_name                 = v_first,
      last_name                  = v_last,
      nickname                   = v_nick,
      email                      = v_email,
      phone                      = v_phone,
      date_of_birth              = v_dob,
      address_line1              = btrim(p_payload ->> 'address_line1'),
      address_line2              = NULLIF(btrim(COALESCE(p_payload ->> 'address_line2','')), ''),
      city                       = btrim(p_payload ->> 'city'),
      state                      = btrim(p_payload ->> 'state'),
      zip_code                   = btrim(p_payload ->> 'zip_code'),
      status                     = 'reference_check',
      status_updated_at          = now(),
      reference_round_started_at = now(),
      updated_at                 = now()
  WHERE id = c.id;

  INSERT INTO public.team_form_secure (candidate_id, agency_id, ssn)
  VALUES (c.id, c.agency_id, v_ssn)
  ON CONFLICT (candidate_id) WHERE candidate_id IS NOT NULL
  DO UPDATE SET ssn = EXCLUDED.ssn, updated_at = now();

  DELETE FROM public.hiring_reference_contacts WHERE candidate_id = c.id;

  FOR v_ref IN SELECT * FROM jsonb_array_elements(v_refs) LOOP
    v_n := v_n + 1;
    EXIT WHEN v_n > 5;
    INSERT INTO public.hiring_reference_contacts
      (agency_id, candidate_id, slot_number, contact_name, relationship, company, phone, email)
    VALUES (
      c.agency_id, c.id, v_n,
      btrim(v_ref ->> 'contact_name'),
      NULLIF(btrim(COALESCE(v_ref ->> 'relationship','')), ''),
      NULLIF(btrim(COALESCE(v_ref ->> 'company','')), ''),
      NULLIF(btrim(COALESCE(v_ref ->> 'phone','')), ''),
      NULLIF(btrim(COALESCE(v_ref ->> 'email','')), '')
    );
  END LOOP;

  -- The team record, built from what they just typed. Pay, role, licences,
  -- State Farm address, hire date and the active flag are not touched.
  v_team := public.hiring_create_team_row_from_candidate(c.id);

  RETURN jsonb_build_object('ok', true, 'candidate_id', c.id,
                            'references_saved', v_n, 'team_member_id', v_team);
END;
$function$;
