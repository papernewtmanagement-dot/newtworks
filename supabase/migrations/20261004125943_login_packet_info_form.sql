-- Peter 2026-10-04: his Print the Day 1 Packet item becomes Fill in Login
-- Packet Info. It opens a form where he types the new hire's packet details,
-- and it checks itself off on his list once they are all filled in.

-- One rule for "has this step's unlock date come". The completion gate,
-- onboarding_step_is_open() and the form sync all ask it here.
CREATE OR REPLACE FUNCTION public.onboarding_unlocked(p_unlocks_on date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT p_unlocks_on IS NULL
      OR p_unlocks_on <= (now() AT TIME ZONE 'America/Chicago')::date;
$function$;

REVOKE ALL ON FUNCTION public.onboarding_unlocked(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_unlocked(date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_missing int;
BEGIN
  -- The Orientation line (the sub-item named by an onboarding_instructions row with kind 'orientation') is ticked by
  -- Peter at orientation, from its pop-up or on the card. Nobody else can tick or untick it. Work with nobody signed
  -- in (the template sync, a migration) is not a person ticking a box.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.substeps_done IS DISTINCT FROM OLD.substeps_done
       AND auth.uid() IS NOT NULL
       AND COALESCE(public.current_app_user_role(), '') <> 'owner'
       AND EXISTS (
         SELECT 1
         FROM public.onboarding_instructions i
         JOIN public.team_onboarding_plans p ON p.id = NEW.plan_id AND p.agency_id = i.agency_id
         WHERE i.kind = 'orientation'
           AND (CASE WHEN jsonb_typeof(OLD.substeps_done) = 'array' THEN OLD.substeps_done ? i.substep_label ELSE false END)
               IS DISTINCT FROM
               (CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ? i.substep_label ELSE false END)
       ) THEN
      RAISE EXCEPTION 'Peter checks off Orientation at orientation.';
    END IF;
  END IF;

  -- Only guard the moment a step goes from open to done.
  IF NEW.completed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.auto_source IS NOT NULL
     AND COALESCE(current_setting('app.onboarding_autotick', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This step fills itself in from the rest of Newtworks. It cannot be ticked by hand.';
  END IF;

  IF NOT public.onboarding_unlocked(NEW.unlocks_on) THEN
    RAISE EXCEPTION 'This step opens on %.', to_char(NEW.unlocks_on, 'Dy Mon FMDD');
  END IF;

  IF array_length(public.onboarding_substep_labels(NEW.substeps), 1) IS NULL THEN
    RETURN NEW;
  END IF;

  v_missing := public.onboarding_substeps_missing(NEW.substeps, NEW.substeps_done);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all the sub-items first. % still open.', v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_step_is_open(p_step_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE((
    SELECT s.completed_at IS NULL
       AND p.status = 'active'
       -- the phase has to have started. A negative offset is pre-start work,
       -- which is open the moment the plan exists.
       AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)
       AND public.onboarding_unlocked(s.unlocks_on)
       AND NOT EXISTS (
         SELECT 1
         FROM unnest(COALESCE(s.blocked_by, ARRAY[]::text[])) b
         JOIN public.team_onboarding_steps bs
           ON bs.plan_id = s.plan_id AND bs.template_key = b
         WHERE bs.completed_at IS NULL)
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    WHERE s.id = p_step_id), false);
$function$;

-- Form lines tick any time. The step itself closes only once its unlock date
-- has come; the gate refuses it before then, and that refusal used to fail the
-- whole save. The hourly run closes it on the day it opens.
CREATE OR REPLACE FUNCTION public.onboarding_sync_form_steps(p_team_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_done  jsonb;
  v_n     int := 0;
BEGIN
  FOR s IN
    SELECT st.id, st.substeps, st.substeps_done, st.completed_at, st.unlocks_on, p.team_member_id
    FROM public.team_onboarding_steps st
    JOIN public.team_onboarding_plans p ON p.id = st.plan_id
    WHERE p.status IN ('active', 'paused')
      AND p.team_member_id IS NOT NULL
      AND (p_team_id IS NULL OR p.team_member_id = p_team_id)
      AND EXISTS (SELECT 1 FROM unnest(public.onboarding_substep_labels(st.substeps)) l
                  WHERE public.onboarding_substep_form_id(l) IS NOT NULL)
  LOOP
    -- Hand-ticked lines stay as they are; form lines follow the form.
    SELECT COALESCE(jsonb_agg(l ORDER BY l), '[]'::jsonb) INTO v_done
    FROM (
      SELECT d AS l
      FROM unnest(public.onboarding_substep_labels(
             CASE WHEN jsonb_typeof(s.substeps_done) = 'array' THEN s.substeps_done ELSE '[]'::jsonb END)) d
      WHERE public.onboarding_substep_form_id(d) IS NULL
      UNION
      SELECT l
      FROM unnest(public.onboarding_substep_labels(s.substeps)) l
      JOIN public.v_team_form_status v
        ON v.team_id = s.team_member_id
       AND v.form_type = public.onboarding_substep_form_id(l)
      WHERE v.state IN ('complete', 'waived')
    ) x;

    IF v_done IS DISTINCT FROM (
         SELECT COALESCE(jsonb_agg(d ORDER BY d), '[]'::jsonb)
         FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(s.substeps_done) = 'array' THEN s.substeps_done ELSE '[]'::jsonb END) d) THEN
      UPDATE public.team_onboarding_steps SET substeps_done = v_done, updated_at = now() WHERE id = s.id;
      v_n := v_n + 1;
    END IF;

    IF s.completed_at IS NULL
       AND public.onboarding_unlocked(s.unlocks_on)
       AND public.onboarding_substeps_missing(s.substeps, v_done) = 0 THEN
      UPDATE public.team_onboarding_steps SET completed_at = now(), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$function$;

-- Same five forms, plus login_packet_info for anyone with an open onboarding
-- plan: complete once all six packet details are on their team record. The
-- start-date filter on the five forms does not apply here, because Peter fills
-- this in before the hire starts.
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
  WHERE (t.is_active IS TRUE OR t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE) AND COALESCE(t.is_test_user, false) = false
UNION ALL
 SELECT t.id AS team_id,
    t.agency_id,
    t.first_name,
    t.last_name,
    'login_packet_info'::text AS form_type,
    NULL::uuid AS submission_id,
    NULL::text AS submission_status,
    NULL::timestamp with time zone AS employee_submitted_at,
    NULL::timestamp with time zone AS employer_completed_at,
    NULL::timestamp with time zone AS locked_at,
    NULL::date AS retention_until,
    NULL::timestamp with time zone AS secure_purged_at,
    NULL::date AS due_date,
    NULL::date AS last_completed_at,
    NULL::integer AS cycle_months,
        CASE
            WHEN NULLIF(btrim(t.sf_alias), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_registration_number), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_initial_password), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_mfa_temp_pass), '') IS NOT NULL
             AND t.sf_mfa_temp_pass_from IS NOT NULL
             AND t.sf_mfa_temp_pass_until IS NOT NULL THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM team t
  WHERE COALESCE(t.is_test_user, false) = false
    AND (EXISTS ( SELECT 1
           FROM team_onboarding_plans p
          WHERE p.team_member_id = t.id AND (p.status = ANY (ARRAY['active'::text, 'paused'::text]))));

-- Saving packet details re-checks that person's form lines right away, through
-- the same trigger function the form tables use.
CREATE OR REPLACE FUNCTION public.tg_onboarding_forms_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Each branch names only the column its own table has.
  IF TG_TABLE_NAME = 'team_form_requirements' THEN
    PERFORM public.onboarding_sync_form_steps(NEW.team_member_id);
  ELSIF TG_TABLE_NAME = 'team' THEN
    PERFORM public.onboarding_sync_form_steps(NEW.id);
  ELSE
    PERFORM public.onboarding_sync_form_steps(NEW.team_id);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_onboarding_packet_info_changed ON public.team;
CREATE TRIGGER trg_onboarding_packet_info_changed
  AFTER UPDATE OF sf_alias, sf_registration_number, sf_initial_password, sf_mfa_temp_pass, sf_mfa_temp_pass_from, sf_mfa_temp_pass_until
  ON public.team
  FOR EACH ROW
  WHEN ((old.sf_alias, old.sf_registration_number, old.sf_initial_password, old.sf_mfa_temp_pass, old.sf_mfa_temp_pass_from, old.sf_mfa_temp_pass_until)
        IS DISTINCT FROM
        (new.sf_alias, new.sf_registration_number, new.sf_initial_password, new.sf_mfa_temp_pass, new.sf_mfa_temp_pass_from, new.sf_mfa_temp_pass_until))
  EXECUTE FUNCTION public.tg_onboarding_forms_changed();
