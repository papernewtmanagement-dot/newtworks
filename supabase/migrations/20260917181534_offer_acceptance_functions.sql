-- =========================================================================
-- The three functions behind the contingent offer acceptance page
-- =========================================================================
-- issue  -> called by the edge function just before the offer email goes out
-- view   -> what the public page is allowed to see
-- accept -> what the candidate sends back
--
-- The page never touches a table directly. The edge function is the only way
-- in and the link is the only key, the same shape as the interview booking
-- page. Nothing here ever hands back the Social Security number.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.hiring_issue_offer_accept_token(
  p_candidate_id uuid,
  p_days         integer DEFAULT 7
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_token text;
BEGIN
  v_token := encode(gen_random_bytes(24), 'hex');

  UPDATE public.hiring_candidates
  SET offer_accept_token      = v_token,
      offer_accept_expires_at = now() + make_interval(days => GREATEST(p_days, 1)),
      updated_at              = now()
  WHERE id = p_candidate_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Candidate % not found', p_candidate_id;
  END IF;

  RETURN v_token;
END;
$function$;

COMMENT ON FUNCTION public.hiring_issue_offer_accept_token(uuid, integer) IS
  'Mints a fresh acceptance link for a candidate and starts its clock. Called at the moment the offer email is sent, so re-sending the offer always replaces a stale or spent link.';


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

  SELECT id, agency_id, first_name, candidate_name, offer_job_title, position,
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
    'job_title',   COALESCE(c.offer_job_title, c.position),
    'reports_to',  c.offer_reports_to,
    'start_date',  c.offer_start_date,
    'respond_by',  c.offer_respond_by,
    'letter_body', c.offer_letter_body,
    'references_wanted', v_asked
  );
END;
$function$;

COMMENT ON FUNCTION public.hiring_offer_accept_view(text) IS
  'Everything the public acceptance page may show. Deliberately returns no Social Security number, no scores and no notes.';


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

  RETURN jsonb_build_object('ok', true, 'candidate_id', c.id, 'references_saved', v_n);
END;
$function$;

COMMENT ON FUNCTION public.hiring_accept_offer(text, jsonb) IS
  'The candidate accepting. Saves their details, files the Social Security number in team_form_secure, records who we should call, moves them to reference check, and clears the link so it cannot be used twice.';

REVOKE ALL ON FUNCTION public.hiring_issue_offer_accept_token(uuid, integer) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.hiring_offer_accept_view(text)                 FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.hiring_accept_offer(text, jsonb)               FROM public, anon, authenticated;
