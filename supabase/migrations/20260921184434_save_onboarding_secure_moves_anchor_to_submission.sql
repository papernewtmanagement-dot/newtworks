-- A secure row has exactly one anchor (team_form_secure_one_anchor_chk).
-- When the number from offer acceptance is carried onto the onboarding form,
-- the row moves from the candidate to the form.
CREATE OR REPLACE FUNCTION public.save_onboarding_secure(p_submission_id uuid, p_ssn text, p_banks jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  s        record;
  v_ssn    text := NULLIF(regexp_replace(COALESCE(p_ssn, ''), '[^0-9]', '', 'g'), '');
  v_cand   uuid;
  v_row    uuid;
BEGIN
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

  IF v_ssn IS NULL AND v_cand IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.team_form_secure WHERE submission_id = s.id AND ssn IS NOT NULL) THEN
    RAISE EXCEPTION 'Social Security number is required';
  END IF;

  IF v_cand IS NOT NULL THEN
    DELETE FROM public.team_form_secure WHERE submission_id = s.id AND id <> v_cand;
    UPDATE public.team_form_secure
       SET submission_id = s.id,
           candidate_id  = NULL,
           ssn   = COALESCE(v_ssn, ssn),
           banks = COALESCE(p_banks, '[]'::jsonb)
     WHERE id = v_cand
     RETURNING id INTO v_row;
  ELSE
    SELECT id INTO v_row FROM public.team_form_secure WHERE submission_id = s.id ORDER BY created_at DESC LIMIT 1;
    IF v_row IS NOT NULL THEN
      UPDATE public.team_form_secure
         SET ssn = COALESCE(v_ssn, ssn), banks = COALESCE(p_banks, '[]'::jsonb)
       WHERE id = v_row;
    ELSE
      INSERT INTO public.team_form_secure (submission_id, agency_id, ssn, banks)
      VALUES (s.id, s.agency_id, v_ssn, COALESCE(p_banks, '[]'::jsonb))
      RETURNING id INTO v_row;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;
