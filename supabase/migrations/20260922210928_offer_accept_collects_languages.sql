-- Languages a new hire speaks, with a self-rated level for each.
-- Shape: [{"language":"Spanish","proficiency":"professional"}, ...]
-- Levels are anchored to the Interagency Language Roundtable (ILR) scale and
-- worded as concrete "can do" tasks, because self-ratings tied to specific tasks
-- track tested ability far better than abstract labels (Ross 1998, Language
-- Testing 15(1), meta-analysis of 60 correlations; speaking r about .6).
--   basic          ~ ILR 1   simple words and phrases
--   conversational ~ ILR 2   everyday conversation
--   professional   ~ ILR 3   could explain a policy to a customer
--   native         ~ ILR 4-5 native or fully fluent

ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS languages jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.team              ADD COLUMN IF NOT EXISTS languages jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_languages_is_array') THEN
    ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_languages_is_array CHECK (jsonb_typeof(languages) = 'array');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'team_languages_is_array') THEN
    ALTER TABLE public.team ADD CONSTRAINT team_languages_is_array CHECK (jsonb_typeof(languages) = 'array');
  END IF;
END $$;

-- The ONE place that checks and cleans a languages list. Returns
-- {ok:true, languages:[...]} or {ok:false, error:...}.
CREATE OR REPLACE FUNCTION public.normalize_languages(p_languages jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_in   jsonb := COALESCE(p_languages, '[]'::jsonb);
  v_out  jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_item jsonb;
  v_lang text;
  v_prof text;
BEGIN
  IF jsonb_typeof(v_in) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_languages');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_in) LOOP
    v_lang := btrim(regexp_replace(COALESCE(v_item ->> 'language', ''), '\s+', ' ', 'g'));
    v_prof := lower(btrim(COALESCE(v_item ->> 'proficiency', '')));
    IF v_lang = '' AND v_prof = '' THEN
      CONTINUE;                                   -- a blank row left on the form
    END IF;
    IF v_lang = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'language_needs_name');
    END IF;
    IF v_prof NOT IN ('basic', 'conversational', 'professional', 'native') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'language_needs_level');
    END IF;
    IF lower(v_lang) = ANY (v_seen) THEN
      CONTINUE;
    END IF;
    v_seen := v_seen || lower(v_lang);
    v_out  := v_out || jsonb_build_array(jsonb_build_object('language', v_lang, 'proficiency', v_prof));
  END LOOP;

  IF jsonb_array_length(v_out) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_languages');
  END IF;
  RETURN jsonb_build_object('ok', true, 'languages', v_out);
END;
$function$;

-- Accept: now requires at least one language with a level, saves it on the candidate.
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
  v_langs    jsonb;
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

  v_langs := public.normalize_languages(p_payload -> 'languages');
  IF NOT COALESCE((v_langs ->> 'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', v_langs ->> 'error');
  END IF;
  v_langs := v_langs -> 'languages';

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
      languages                  = v_langs,
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

-- Team row now carries the languages too.
CREATE OR REPLACE FUNCTION public.hiring_create_team_row_from_candidate(p_candidate_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c      record;
  v_team uuid;
BEGIN
  SELECT id, agency_id, first_name, last_name, candidate_name, nickname,
         email, phone, address_line1, address_line2, city, state, zip_code,
         date_of_birth, offer_start_date, offer_role_key, team_member_id,
         offer_role, offer_role_category, offer_role_level,
         offer_pay_type, offer_pay_amount, offer_pay_period, languages
  INTO c
  FROM public.hiring_candidates
  WHERE id = p_candidate_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF c.team_member_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.team t WHERE t.id = c.team_member_id) THEN
    RETURN c.team_member_id;
  END IF;

  INSERT INTO public.team (
    agency_id, first_name, last_name, nickname,
    email_personal, phone_personal,
    address_line1, address_line2, city, state, zip_code,
    date_of_birth, start_date, category, is_active,
    role, role_category, role_level,
    employment_type, pay_type, pay_rate, pay_frequency,
    login_invite_due, languages
  )
  VALUES (
    c.agency_id,
    COALESCE(NULLIF(btrim(COALESCE(c.first_name,'')), ''),
             NULLIF(split_part(COALESCE(c.candidate_name,''), ' ', 1), ''), ''),
    COALESCE(NULLIF(btrim(COALESCE(c.last_name,'')), ''),
             NULLIF(split_part(COALESCE(c.candidate_name,''), ' ', 2), ''), ''),
    NULLIF(btrim(COALESCE(c.nickname,'')), ''),
    NULLIF(btrim(COALESCE(c.email,'')), ''),
    NULLIF(btrim(COALESCE(c.phone,'')), ''),
    c.address_line1, c.address_line2, c.city, c.state, c.zip_code,
    c.date_of_birth,
    c.offer_start_date,
    'agency',
    false,
    NULLIF(btrim(COALESCE(c.offer_role,'')), ''),
    COALESCE(NULLIF(btrim(COALESCE(c.offer_role_category,'')), ''),
      CASE c.offer_role_key
        WHEN 'retention' THEN 'Retention'
        WHEN 'sales' THEN 'Sales'
        WHEN 'life_specialist' THEN 'Sales'
        ELSE NULL
      END),
    NULLIF(btrim(COALESCE(c.offer_role_level,'')), ''),
    'Full Time',
    CASE lower(COALESCE(c.offer_pay_type,''))
      WHEN 'salary' THEN 'SALARY'
      WHEN 'hourly' THEN 'HOURLY'
      ELSE NULL
    END,
    -- Salaries are held as the weekly paycheck, hourly as the hourly rate.
    CASE
      WHEN c.offer_pay_amount IS NULL THEN NULL
      WHEN lower(COALESCE(c.offer_pay_type,'')) = 'salary' AND c.offer_pay_period = 'year'
        THEN round(c.offer_pay_amount / 52.0, 2)
      WHEN lower(COALESCE(c.offer_pay_type,'')) = 'hourly'
        THEN c.offer_pay_amount
      ELSE NULL
    END,
    'weekly',
    c.offer_start_date,
    COALESCE(c.languages, '[]'::jsonb)
  )
  RETURNING id INTO v_team;

  UPDATE public.hiring_candidates
  SET team_member_id = v_team, updated_at = now()
  WHERE id = c.id;

  RETURN v_team;
END;
$function$;

-- View: hand back any languages already on file so the page can prefill them.
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
         offer_accept_expires_at, offer_accepted_at, languages
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
    'prefill_languages',  COALESCE(c.languages, '[]'::jsonb),
    'job_title',   COALESCE(c.offer_job_title, c.position),
    'reports_to',  c.offer_reports_to,
    'start_date',  c.offer_start_date,
    'respond_by',  c.offer_respond_by,
    'letter_body', c.offer_letter_body,
    'references_wanted', v_asked
  );
END;
$function$;
