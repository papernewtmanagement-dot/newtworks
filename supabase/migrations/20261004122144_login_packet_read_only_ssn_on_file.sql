-- Peter 2026-10-04: the login packet is read-only. The new hire reads it and
-- follows along; nothing is submitted. Its line on the Login card opens it and
-- is ticked by hand. Also 1A: the Onboarding form asks for the Social Security
-- number only when none is on file.

-- The status view goes back to the five forms that are filled in.
CREATE OR REPLACE VIEW public.v_team_form_status WITH (security_invoker = true) AS
 SELECT t.id AS team_id,
    t.agency_id,
    t.first_name,
    t.last_name,
    f.form_type,
    s.id AS submission_id,
    s.status AS submission_status,
    s.employee_submitted_at,
    s.employer_completed_at,
    s.locked_at,
    s.retention_until,
    s.secure_purged_at,
    r.due_date,
    r.last_completed_at,
    r.cycle_months,
        CASE
            WHEN f.form_type = 'handbook_ack'::text THEN
            CASE
                WHEN r.id IS NULL OR (r.status = ANY (ARRAY['due'::text, 'active'::text])) THEN 'action_needed'::text
                WHEN r.due_date <= CURRENT_DATE AND r.cycle_months IS NOT NULL THEN 'action_needed'::text
                WHEN r.status = 'waived'::text THEN 'waived'::text
                ELSE 'complete'::text
            END
            WHEN s.id IS NULL THEN 'action_needed'::text
            WHEN f.form_type = 'i9'::text AND s.employer_completed_at IS NULL THEN 'awaiting_employer'::text
            WHEN s.status = ANY (ARRAY['submitted'::text, 'locked'::text]) THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM team t
     CROSS JOIN ( VALUES ('combined_onboarding'::text), ('w4'::text), ('non_compete'::text), ('handbook_ack'::text), ('i9'::text)) f(form_type)
     LEFT JOIN team_form_requirements r ON r.team_member_id = t.id AND r.form_type = f.form_type
     LEFT JOIN LATERAL ( SELECT s2.id,
            s2.agency_id,
            s2.team_id,
            s2.form_type,
            s2.cycle_key,
            s2.document_id,
            s2.status,
            s2.data,
            s2.employee_submitted_at,
            s2.employer_section,
            s2.employer_completed_by,
            s2.employer_completed_at,
            s2.locked_at,
            s2.retention_until,
            s2.created_at,
            s2.updated_at,
            s2.secure_purged_at,
            s2.secure_purged_by
           FROM team_form_submissions s2
          WHERE s2.team_id = t.id AND s2.form_type = f.form_type AND s2.status <> 'superseded'::text
          ORDER BY s2.created_at DESC
         LIMIT 1) s ON true
  WHERE (t.is_active IS TRUE OR t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE) AND COALESCE(t.is_test_user, false) = false;

-- Nothing is ever submitted for the packet, so it leaves the allowed list.
ALTER TABLE public.team_form_submissions
  DROP CONSTRAINT IF EXISTS team_form_submissions_form_type_check;
ALTER TABLE public.team_form_submissions
  ADD CONSTRAINT team_form_submissions_form_type_check
  CHECK (form_type = ANY (ARRAY['combined_onboarding'::text, 'w4'::text, 'non_compete'::text, 'handbook_ack'::text, 'i9'::text]));

-- The form whose status ticks a line. A read-only form (the login packet)
-- opens from its line but never ticks it, so that line is ticked by hand.
-- Mirrored by tickingFormOf() in src/lib/onboardingUi.jsx.
CREATE OR REPLACE FUNCTION public.onboarding_substep_form_id(p_label text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(substring(p_label from '[?&]form=([a-z0-9_]+)'), 'login_packet');
$function$;

-- One rule for "is a Social Security number on file for this person": the one
-- given with the offer, or one saved with their Onboarding form. The form asks
-- for it only when this is false; save_onboarding_secure requires it the same way.
CREATE OR REPLACE FUNCTION public.onboarding_ssn_on_file(p_team_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (p_team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  RETURN EXISTS (
           SELECT 1
           FROM public.team_form_secure sec
           JOIN public.hiring_candidates hc ON hc.id = sec.candidate_id
           WHERE hc.team_member_id = p_team_id
             AND sec.submission_id IS NULL
             AND sec.ssn IS NOT NULL)
      OR EXISTS (
           SELECT 1
           FROM public.team_form_secure sec
           JOIN public.team_form_submissions s ON s.id = sec.submission_id
           WHERE s.team_id = p_team_id
             AND s.form_type = 'combined_onboarding'
             AND sec.ssn IS NOT NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.onboarding_ssn_on_file(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_ssn_on_file(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_onboarding_secure(p_submission_id uuid, p_ssn text, p_banks jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s        record;
  v_ssn    text := NULLIF(regexp_replace(COALESCE(p_ssn, ''), '[^0-9]', '', 'g'), '');
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
$function$;
