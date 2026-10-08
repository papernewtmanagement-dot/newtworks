-- Onboarding form: the database refuses to lock it without "need to make",
-- "want to make" and one complete bank account. The page already checks this,
-- but a page left open from before a change can skip the page's check
-- (Bryson, Oct 5 2026). Also: a resubmit with the bank boxes left empty keeps
-- the bank already on file instead of wiping it.

-- One test for "is this a usable bank account", used everywhere below.
CREATE OR REPLACE FUNCTION public.onboarding_bank_complete(p_banks jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_banks) = 'array' THEN p_banks ELSE '[]'::jsonb END) b
    WHERE length(btrim(coalesce(b->>'bank_name', ''))) > 0
      AND length(regexp_replace(coalesce(b->>'routing_number', ''), '[^0-9]', '', 'g')) = 9
      AND length(regexp_replace(coalesce(b->>'account_number', ''), '[^0-9]', '', 'g')) >= 4
  );
$$;

-- Is a usable bank already on this person's onboarding form?
CREATE OR REPLACE FUNCTION public.onboarding_bank_on_file(p_team_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (p_team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM public.team_form_secure sec
    JOIN public.team_form_submissions s ON s.id = sec.submission_id
    WHERE s.team_id = p_team_id
      AND s.form_type = 'combined_onboarding'
      AND public.onboarding_bank_complete(sec.banks));
END;
$$;
GRANT EXECUTE ON FUNCTION public.onboarding_bank_on_file(uuid) TO authenticated;

-- Same as before, except empty bank boxes keep the bank already on file.
CREATE OR REPLACE FUNCTION public.save_onboarding_secure(p_submission_id uuid, p_ssn text, p_banks jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s        record;
  v_ssn    text := NULLIF(regexp_replace(COALESCE(p_ssn, ''), '[^0-9]', '', 'g'), '');
  v_new    boolean := public.onboarding_bank_complete(p_banks);
  v_cand   uuid;
  v_row    uuid;
BEGIN
  PERFORM public.require_login('staff');
  SELECT id, agency_id, team_id, form_type INTO s
  FROM public.team_form_submissions WHERE id = p_submission_id;
  IF NOT FOUND OR s.form_type <> 'combined_onboarding' THEN
    RAISE EXCEPTION 'Onboarding form not found';
  END IF;
  IF NOT (s.team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  IF v_ssn IS NOT NULL AND length(v_ssn) <> 9 THEN
    RAISE EXCEPTION 'Social Security number must be 9 digits';
  END IF;

  -- The number they gave when they accepted the offer, if any.
  SELECT sec.id INTO v_cand
  FROM public.team_form_secure sec
  JOIN public.hiring_candidates hc ON hc.id = sec.candidate_id
  WHERE hc.team_member_id = s.team_id AND sec.submission_id IS NULL
  ORDER BY sec.created_at DESC LIMIT 1;

  IF v_ssn IS NULL AND NOT public.onboarding_ssn_on_file(s.team_id) THEN
    RAISE EXCEPTION 'Social Security number is required';
  END IF;

  IF v_cand IS NOT NULL THEN
    DELETE FROM public.team_form_secure WHERE submission_id = s.id AND id <> v_cand;
    UPDATE public.team_form_secure
       SET submission_id = s.id,
           candidate_id  = NULL,
           ssn   = COALESCE(v_ssn, ssn),
           banks = CASE WHEN v_new THEN p_banks ELSE COALESCE(banks, '[]'::jsonb) END
     WHERE id = v_cand
     RETURNING id INTO v_row;
  ELSE
    SELECT id INTO v_row FROM public.team_form_secure WHERE submission_id = s.id ORDER BY created_at DESC LIMIT 1;
    IF v_row IS NOT NULL THEN
      UPDATE public.team_form_secure
         SET ssn = COALESCE(v_ssn, ssn),
             banks = CASE WHEN v_new THEN p_banks ELSE COALESCE(banks, '[]'::jsonb) END
       WHERE id = v_row;
    ELSE
      INSERT INTO public.team_form_secure (submission_id, agency_id, ssn, banks)
      VALUES (s.id, s.agency_id, v_ssn, CASE WHEN v_new THEN p_banks ELSE '[]'::jsonb END)
      RETURNING id INTO v_row;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- The lock refuses an Onboarding form missing the two income answers or a bank.
CREATE OR REPLACE FUNCTION public.tg_team_form_lock()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.form_type = 'combined_onboarding' AND NEW.status = 'submitted' AND NEW.locked_at IS NULL THEN
    IF length(btrim(coalesce(NEW.data->>'need_to_make', ''))) = 0
       OR length(btrim(coalesce(NEW.data->>'want_to_make', ''))) = 0 THEN
      RAISE EXCEPTION 'Fill in what you need to make and what you want to make, then press Submit again.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.team_form_secure sec
                   WHERE sec.submission_id = NEW.id
                     AND public.onboarding_bank_complete(sec.banks)) THEN
      RAISE EXCEPTION 'Fill in your bank name, 9-digit routing number and account number, then press Submit again.';
    END IF;
  END IF;

  IF NEW.status = 'submitted' AND NEW.employee_submitted_at IS NULL THEN
    NEW.employee_submitted_at := now();
  END IF;

  IF NEW.form_type = 'i9' THEN
    NEW.retention_until := public.i9_retention_date(NEW.team_id);
    IF NEW.employer_completed_at IS NOT NULL AND NEW.locked_at IS NULL THEN
      NEW.locked_at := now();
      NEW.status := 'locked';
    END IF;
  ELSIF NEW.status = 'submitted' AND NEW.locked_at IS NULL THEN
    NEW.locked_at := now();
    NEW.status := 'locked';
  END IF;

  -- The IRS asks employers to keep a W-4 for at least four years.
  IF NEW.form_type = 'w4' AND NEW.locked_at IS NOT NULL AND NEW.retention_until IS NULL THEN
    NEW.retention_until := (NEW.locked_at + interval '4 years')::date;
  END IF;

  RETURN NEW;
END;
$function$;
