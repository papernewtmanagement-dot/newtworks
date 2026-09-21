-- Accepting an offer now sets up everything the hire needs before day one,
-- and the onboarding form works for the hire themselves on day one.

-- 1) One function that gives a team member their onboarding plan.
--    A plan already started for them as a candidate is attached; otherwise a
--    new one is built from the templates. Never throws: a missing template
--    raises an alert instead of breaking whatever called it.
CREATE OR REPLACE FUNCTION public.onboarding_ensure_plan_for_team_member(
  p_team_member_id uuid, p_candidate_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_plan  uuid;
  v_start date;
  v_agency uuid;
  v_name  text;
BEGIN
  IF p_team_member_id IS NULL THEN RETURN NULL; END IF;

  SELECT id INTO v_plan FROM public.team_onboarding_plans
  WHERE team_member_id = p_team_member_id AND status IN ('active','paused')
  LIMIT 1;
  IF v_plan IS NOT NULL THEN RETURN v_plan; END IF;

  IF p_candidate_id IS NOT NULL THEN
    SELECT id INTO v_plan FROM public.team_onboarding_plans
    WHERE candidate_id = p_candidate_id AND status IN ('active','paused')
    ORDER BY created_at DESC LIMIT 1;
    IF v_plan IS NOT NULL THEN
      PERFORM public.attach_onboarding_plan_to_team_member(v_plan, p_team_member_id);
      RETURN v_plan;
    END IF;
  END IF;

  SELECT agency_id, COALESCE(start_date, CURRENT_DATE),
         TRIM(COALESCE(nickname, first_name, '') || ' ' || COALESCE(last_name, ''))
  INTO v_agency, v_start, v_name
  FROM public.team WHERE id = p_team_member_id;

  BEGIN
    v_plan := public.create_onboarding_plan(
      p_team_member_id := p_team_member_id,
      p_start_date     := v_start);
  EXCEPTION WHEN others THEN
    PERFORM 1 FROM public.alerts
      WHERE alert_type = 'onboarding_plan_not_created' AND related_id = p_team_member_id AND is_resolved = false;
    IF NOT FOUND THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved)
      VALUES (v_agency, 'onboarding_plan_not_created', 'warning',
              'No onboarding plan for ' || COALESCE(NULLIF(v_name, ''), 'a new hire'),
              'The plan could not be built automatically: ' || SQLERRM || '. Set their role on the team record, then create the plan from Onboarding.',
              'onboarding', p_team_member_id, false, false);
    END IF;
    RETURN NULL;
  END;
  RETURN v_plan;
END;
$$;

-- 2) The team row built at acceptance also carries the role category from the
--    offer and waits for its login invite until the start date.
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
         date_of_birth, offer_start_date, offer_role_key, team_member_id
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
    role_category, login_invite_due
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
    CASE c.offer_role_key
      WHEN 'retention' THEN 'Retention'
      WHEN 'sales' THEN 'Sales'
      WHEN 'life_specialist' THEN 'Sales'
      ELSE NULL
    END,
    c.offer_start_date
  )
  RETURNING id INTO v_team;

  UPDATE public.hiring_candidates
  SET team_member_id = v_team, updated_at = now()
  WHERE id = c.id;

  RETURN v_team;
END;
$function$;

-- 3) Acceptance: after the team row, make sure the onboarding plan exists.
DO $mig$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.hiring_accept_offer'::regproc);
  IF position('onboarding_ensure_plan_for_team_member' in v_def) = 0 THEN
    v_def := replace(v_def,
      E'  v_team := public.hiring_create_team_row_from_candidate(c.id);\n',
      E'  v_team := public.hiring_create_team_row_from_candidate(c.id);\n\n  -- Their onboarding plan, attached from the candidate stage or built new.\n  PERFORM public.onboarding_ensure_plan_for_team_member(v_team, c.id);\n');
    IF position('onboarding_ensure_plan_for_team_member' in v_def) = 0 THEN
      RAISE EXCEPTION 'hiring_accept_offer anchor not found';
    END IF;
    EXECUTE v_def;
  END IF;
END
$mig$;

-- 4) A hire whose start date is filled in later still gets a start-day invite.
CREATE OR REPLACE FUNCTION public.team_follow_start_date_for_invite()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.start_date IS NULL OR NEW.start_date IS NOT DISTINCT FROM OLD.start_date THEN
    RETURN NEW;
  END IF;
  -- An invite is already waiting: move it with the date.
  IF NEW.login_invite_due IS NOT NULL
     AND NEW.login_invite_due IS NOT DISTINCT FROM OLD.login_invite_due THEN
    NEW.login_invite_due := NEW.start_date;
  -- Never invited and never had a date: this is the first start date for an
  -- incoming hire, so their invite goes out that morning.
  ELSIF OLD.start_date IS NULL AND NEW.login_invite_due IS NULL
        AND NEW.user_id IS NULL AND NEW.archived_at IS NULL AND NEW.end_date IS NULL
        AND NEW.email_personal IS NOT NULL THEN
    NEW.login_invite_due := NEW.start_date;
  END IF;
  RETURN NEW;
END;
$$;

-- 5) The Social Security number: the hire can save it (the table only let
--    Peter and managers write), and one given at offer acceptance is reused
--    instead of asked for twice.
CREATE OR REPLACE FUNCTION public.onboarding_ssn_on_file(p_team_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT (p_team_id = public.current_team_member_id() OR public.is_agency_admin())
     AND EXISTS (
       SELECT 1 FROM public.team_form_secure sec
       WHERE sec.ssn IS NOT NULL AND (
         sec.submission_id IN (SELECT s.id FROM public.team_form_submissions s WHERE s.team_id = p_team_id)
         OR sec.candidate_id IN (SELECT hc.id FROM public.hiring_candidates hc WHERE hc.team_member_id = p_team_id)
       ));
$$;

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

REVOKE ALL ON FUNCTION public.save_onboarding_secure(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_onboarding_secure(uuid, text, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.onboarding_ssn_on_file(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_ssn_on_file(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.onboarding_ensure_plan_for_team_member(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_ensure_plan_for_team_member(uuid, uuid) TO authenticated;

-- 6) Destroy also removes a number held from offer acceptance.
CREATE OR REPLACE FUNCTION public.purge_team_form_secure(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_deleted integer := 0; v_by uuid;
BEGIN
  IF NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;

  v_by := public.current_team_member_id();

  WITH target AS (
    SELECT sec.id
      FROM public.team_form_secure sec
      JOIN public.team_form_submissions s ON s.id = sec.submission_id
     WHERE s.team_id = p_team_id
    UNION
    SELECT sec.id
      FROM public.team_form_secure sec
      JOIN public.hiring_candidates hc ON hc.id = sec.candidate_id
     WHERE hc.team_member_id = p_team_id
  ), gone AS (
    DELETE FROM public.team_form_secure
     WHERE id IN (SELECT id FROM target)
     RETURNING 1
  )
  SELECT count(*) INTO v_deleted FROM gone;

  UPDATE public.team_form_submissions
     SET secure_purged_at = now(), secure_purged_by = v_by
   WHERE team_id = p_team_id
     AND form_type = 'combined_onboarding'
     AND secure_purged_at IS NULL;

  RETURN jsonb_build_object('deleted', v_deleted, 'purged_at', now());
END;
$function$;

-- 7) Forms show from the start date, not only once someone flips the team
--    record to active.
CREATE OR REPLACE VIEW public.v_team_form_status AS
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
            WHEN (f.form_type = ANY (ARRAY['annual_certification'::text, 'handbook_ack'::text])) THEN
            CASE
                WHEN ((r.id IS NULL) OR (r.status = ANY (ARRAY['due'::text, 'active'::text]))) THEN 'action_needed'::text
                WHEN ((r.due_date <= CURRENT_DATE) AND (r.cycle_months IS NOT NULL)) THEN 'action_needed'::text
                WHEN (r.status = 'waived'::text) THEN 'waived'::text
                ELSE 'complete'::text
            END
            WHEN (s.id IS NULL) THEN 'action_needed'::text
            WHEN ((f.form_type = 'i9'::text) AND (s.employer_completed_at IS NULL)) THEN 'awaiting_employer'::text
            WHEN (s.status = ANY (ARRAY['submitted'::text, 'locked'::text])) THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM (((team t
     CROSS JOIN ( VALUES ('combined_onboarding'::text), ('non_compete'::text), ('annual_certification'::text), ('handbook_ack'::text), ('i9'::text)) f(form_type))
     LEFT JOIN team_form_requirements r ON (((r.team_member_id = t.id) AND (r.form_type = f.form_type))))
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
          WHERE ((s2.team_id = t.id) AND (s2.form_type = f.form_type) AND (s2.status <> 'superseded'::text))
          ORDER BY s2.created_at DESC
         LIMIT 1) s ON (true))
  WHERE ((t.is_active IS TRUE
          OR (t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE))
         AND (COALESCE(t.is_test_user, false) = false));
