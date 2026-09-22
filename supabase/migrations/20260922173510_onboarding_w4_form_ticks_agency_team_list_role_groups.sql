-- Onboarding + forms, Peter 2026-09-22 (fifth pass).
-- 1) W-4 is a form on the site (form_type 'w4'), kept four years like the IRS asks.
-- 2) A sub-item that links to a site form (…?form=<id>) ticks itself from
--    v_team_form_status. onboarding_sync_form_steps() is the one place that
--    happens; form saves and requirement changes call it, and so does the
--    hourly notices run. The Paperwork card's list IS the forms list now.
-- 3) The team list is the active AGENCY team (category 'agency').
--    onboarding_team_list_names() is the one place that list is decided; the
--    fill, and the template page, both read it.
-- 4) A step can also be assigned to everyone in a role category
--    (assign_role_category, e.g. 'Retention') on top of its one named owner.
--    Each of them can see it and gets a task (created_by 'onboarding_group');
--    finishing the step closes them all.

-- ─── 1) W-4 ─────────────────────────────────────────────────────────────
DO $mig$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.team_form_submissions'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%combined_onboarding%'
  LOOP
    EXECUTE format('ALTER TABLE public.team_form_submissions DROP CONSTRAINT %I', r.conname);
  END LOOP;
END
$mig$;
ALTER TABLE public.team_form_submissions ADD CONSTRAINT team_form_submissions_form_type_check
  CHECK (form_type = ANY (ARRAY['combined_onboarding','w4','non_compete','annual_certification','handbook_ack','i9']));

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
            WHEN f.form_type = ANY (ARRAY['annual_certification'::text, 'handbook_ack'::text]) THEN
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
     CROSS JOIN ( VALUES ('combined_onboarding'::text), ('w4'::text), ('non_compete'::text), ('annual_certification'::text), ('handbook_ack'::text), ('i9'::text)) f(form_type)
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
ALTER VIEW public.v_team_form_status SET (security_invoker = true);

CREATE OR REPLACE FUNCTION public.tg_team_form_lock()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
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

-- ─── 2) form sub-items tick themselves ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.onboarding_substep_form_id(p_label text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT substring(p_label from '[?&]form=([a-z0-9_]+)');
$$;

CREATE OR REPLACE FUNCTION public.onboarding_sync_form_steps(p_team_id uuid DEFAULT NULL)
RETURNS int
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
    SELECT st.id, st.substeps, st.substeps_done, st.completed_at, p.team_member_id
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

    IF s.completed_at IS NULL AND public.onboarding_substeps_missing(s.substeps, v_done) = 0 THEN
      UPDATE public.team_onboarding_steps SET completed_at = now(), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.tg_onboarding_forms_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Each branch names only the column its own table has.
  IF TG_TABLE_NAME = 'team_form_requirements' THEN
    PERFORM public.onboarding_sync_form_steps(NEW.team_member_id);
  ELSE
    PERFORM public.onboarding_sync_form_steps(NEW.team_id);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_onboarding_forms_changed ON public.team_form_submissions;
CREATE TRIGGER trg_onboarding_forms_changed
  AFTER INSERT OR UPDATE ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.tg_onboarding_forms_changed();
DROP TRIGGER IF EXISTS trg_onboarding_forms_changed ON public.team_form_requirements;
CREATE TRIGGER trg_onboarding_forms_changed
  AFTER INSERT OR UPDATE ON public.team_form_requirements
  FOR EACH ROW EXECUTE FUNCTION public.tg_onboarding_forms_changed();

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_open_step_notices(uuid,uuid)'::regprocedure);
  v_new := replace(v_def,
$a$  PERFORM public.onboarding_team_card_notices(p_agency_id);$a$,
$b$  PERFORM public.onboarding_team_card_notices(p_agency_id);
  PERFORM public.onboarding_sync_form_steps(NULL);$b$);
  IF v_new = v_def THEN RAISE EXCEPTION 'onboarding_open_step_notices patch did not apply'; END IF;
  EXECUTE v_new;
END
$mig$;

-- ─── 3) the team list ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.onboarding_team_list_names(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_exclude_team_id uuid DEFAULT NULL)
RETURNS text[]
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(array_agg(n ORDER BY n), ARRAY[]::text[])
  FROM (
    SELECT DISTINCT public.onboarding_team_label(tm) AS n
    FROM public.team tm
    WHERE tm.agency_id = p_agency_id
      AND tm.category = 'agency'
      AND tm.is_active IS TRUE
      AND tm.archived_at IS NULL
      AND COALESCE(tm.is_test_user, false) = false
      AND tm.id IS DISTINCT FROM p_exclude_team_id
  ) x
  WHERE n IS NOT NULL;
$$;
GRANT EXECUTE ON FUNCTION public.onboarding_team_list_names(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.onboarding_fill_substeps(p_substeps jsonb, p_plan_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_substeps) <> 'array' OR p_substeps IS NULL THEN p_substeps
    WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_substeps) e
                     WHERE jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list') THEN p_substeps
    ELSE (
      SELECT jsonb_agg(
               CASE WHEN jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list'
                    THEN jsonb_set(e, '{items}', to_jsonb(
                           (SELECT public.onboarding_team_list_names(p.agency_id, p.team_member_id)
                            FROM public.team_onboarding_plans p WHERE p.id = p_plan_id)))
                    ELSE e END
               ORDER BY ord)
      FROM jsonb_array_elements(p_substeps) WITH ORDINALITY AS x(e, ord)
    )
  END;
$$;

DROP TRIGGER IF EXISTS trg_team_onboarding_team_list ON public.team;
CREATE TRIGGER trg_team_onboarding_team_list
  AFTER INSERT OR DELETE OR UPDATE OF first_name, last_name, nickname, is_active, archived_at, is_test_user, category, role_category
  ON public.team
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.onboarding_templates_changed();

-- ─── 4) assign to a role category too ───────────────────────────────────
ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS assign_role_category text;
ALTER TABLE public.team_onboarding_steps     ADD COLUMN IF NOT EXISTS assign_role_category text;

CREATE OR REPLACE FUNCTION public.onboarding_plan_subject_name(p_plan_id uuid)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    CASE WHEN p.team_member_id IS NOT NULL THEN
      (SELECT COALESCE(NULLIF(TRIM(COALESCE(nickname, first_name) || ' ' || COALESCE(last_name,'')), ''), 'New hire')
       FROM public.team WHERE id = p.team_member_id)
    ELSE
      (SELECT COALESCE(NULLIF(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), ''), candidate_name, 'Candidate')
       FROM public.hiring_candidates WHERE id = p.candidate_id)
    END, 'New hire')
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_step_due_on(p_agency_id uuid, p_phase int, p_start date, p_unlocks_on date)
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(CURRENT_DATE,
                  COALESCE(p_unlocks_on,
                           public.onboarding_phase_opens_on(p_agency_id, p_phase, p_start),
                           COALESCE(p_start, CURRENT_DATE)));
$$;

CREATE OR REPLACE FUNCTION public.onboarding_sync_group_tasks(p_plan_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  p   record;
  s   record;
  v_n int := 0;
  v_k int;
BEGIN
  SELECT * INTO p FROM public.team_onboarding_plans WHERE id = p_plan_id;
  IF NOT FOUND OR p.status NOT IN ('active', 'paused') THEN RETURN 0; END IF;

  -- Open group tasks for people no longer in the group, or on steps that
  -- dropped their group, go.
  DELETE FROM public.tasks t
  USING public.team_onboarding_steps st
  WHERE st.plan_id = p_plan_id
    AND t.related_id = st.id
    AND t.created_by = 'onboarding_group'
    AND t.status <> 'completed'
    AND (st.assign_role_category IS NULL OR NOT EXISTS (
           SELECT 1 FROM public.users u JOIN public.team tm ON tm.id = u.team_member_id
           WHERE u.id = t.assigned_to
             AND tm.role_category = st.assign_role_category
             AND tm.is_active IS TRUE AND tm.archived_at IS NULL));

  FOR s IN
    SELECT st.id, st.title, st.description, st.phase, st.assign_role_category, st.assigned_to,
           st.completed_at, st.unlocks_on, ph.name AS phase_name
    FROM public.team_onboarding_steps st
    LEFT JOIN public.onboarding_phases ph ON ph.agency_id = p.agency_id AND ph.phase = st.phase
    WHERE st.plan_id = p_plan_id AND st.assign_role_category IS NOT NULL
  LOOP
    INSERT INTO public.tasks (agency_id, title, description, assigned_to, task_category, task_type,
                              status, due_date, related_id, created_by, completed_at)
    SELECT p.agency_id,
           'Onboarding — ' || public.onboarding_plan_subject_name(p_plan_id) || ': ' || s.title,
           COALESCE(s.description, '') || CASE WHEN s.phase_name IS NULL THEN '' ELSE E'\n\nPhase: ' || s.phase_name END,
           u.id, 'admin', 'task',
           CASE WHEN s.completed_at IS NOT NULL THEN 'completed' ELSE 'open' END,
           public.onboarding_step_due_on(p.agency_id, s.phase, p.start_date, s.unlocks_on),
           s.id, 'onboarding_group', s.completed_at
    FROM public.team tm
    JOIN public.users u ON u.team_member_id = tm.id
    WHERE tm.agency_id = p.agency_id
      AND tm.is_active IS TRUE AND tm.archived_at IS NULL
      AND COALESCE(tm.is_test_user, false) = false
      AND tm.role_category = s.assign_role_category
      AND tm.id IS DISTINCT FROM s.assigned_to
      AND tm.id IS DISTINCT FROM p.team_member_id
      AND NOT EXISTS (SELECT 1 FROM public.tasks k
                      WHERE k.related_id = s.id AND k.created_by = 'onboarding_group' AND k.assigned_to = u.id);
    GET DIAGNOSTICS v_k = ROW_COUNT;
    v_n := v_n + v_k;
  END LOOP;
  RETURN v_n;
END;
$function$;

DO $mig$
DECLARE v_def text; v_new text; v_before int; v_after int;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_new := v_def;
  v_new := replace(v_new,
$a$unlock_rule, unlocks_on, widget
  )$a$,
$b$unlock_rule, unlocks_on, widget, assign_role_category
  )$b$);
  v_new := replace(v_new,
$a$p.start_date), t.widget
  FROM public.onboarding_templates_for_plan(p_plan_id) t$a$,
$b$p.start_date), t.widget, t.assign_role_category
  FROM public.onboarding_templates_for_plan(p_plan_id) t$b$);
  v_new := replace(v_new,
$a$      widget                = t.widget,$a$,
$b$      widget                = t.widget,
      assign_role_category  = t.assign_role_category,$b$);
  v_new := replace(v_new,
$a$s.unlock_rule, s.unlocks_on, s.widget)$a$,
$b$s.unlock_rule, s.unlocks_on, s.widget, s.assign_role_category)$b$);
  v_new := replace(v_new,
$a$p.start_date), t.widget)$a$,
$b$p.start_date), t.widget, t.assign_role_category)$b$);
  -- one subject-name rule
  v_new := replace(v_new,
$a$  IF p.team_member_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(TRIM(COALESCE(nickname, first_name) || ' ' || COALESCE(last_name,'')), ''), 'New hire')
      INTO v_subject FROM public.team WHERE id = p.team_member_id;
  ELSE
    SELECT COALESCE(NULLIF(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), ''), candidate_name, 'Candidate')
      INTO v_subject FROM public.hiring_candidates WHERE id = p.candidate_id;
  END IF;
  v_subject := COALESCE(v_subject, 'New hire');$a$,
$b$  v_subject := public.onboarding_plan_subject_name(p_plan_id);$b$);
  -- one due-date rule
  v_before := (length(v_new) - length(replace(v_new, 'COALESCE(r.unlocks_on,', ''))) / length('COALESCE(r.unlocks_on,');
  v_new := regexp_replace(v_new,
    'GREATEST\(\s*CURRENT_DATE,\s*COALESCE\(r\.unlocks_on,\s*public\.onboarding_phase_opens_on\(p\.agency_id, r\.phase, p\.start_date\),\s*COALESCE\(p\.start_date, CURRENT_DATE\)\)\)',
    'public.onboarding_step_due_on(p.agency_id, r.phase, p.start_date, r.unlocks_on)', 'g');
  v_after := (length(v_new) - length(replace(v_new, 'onboarding_step_due_on(p.agency_id, r.phase', ''))) / length('onboarding_step_due_on(p.agency_id, r.phase');
  -- group tasks after the step rows are right
  v_new := replace(v_new,
$a$  RETURN jsonb_build_object(
    'plan_id', p_plan_id, 'added'$a$,
$b$  PERFORM public.onboarding_sync_group_tasks(p_plan_id);

  RETURN jsonb_build_object(
    'plan_id', p_plan_id, 'added'$b$);

  IF position('widget, assign_role_category' IN v_new) = 0
     OR position('t.widget, t.assign_role_category' IN v_new) = 0
     OR position('assign_role_category  = t.assign_role_category' IN v_new) = 0
     OR position('s.widget, s.assign_role_category)' IN v_new) = 0
     OR position('v_subject := public.onboarding_plan_subject_name(p_plan_id);' IN v_new) = 0
     OR v_before <> 2 OR v_after <> 2
     OR position('PERFORM public.onboarding_sync_group_tasks(p_plan_id);' IN v_new) = 0 THEN
    RAISE EXCEPTION 'onboarding_sync_plan patch did not apply cleanly (%, %)', v_before, v_after;
  END IF;
  EXECUTE v_new;
END
$mig$;

CREATE OR REPLACE FUNCTION public.onboarding_can_see_step(p_plan_id uuid, p_phase integer, p_assigned_to uuid, p_auto_source text, p_owner_kind text, p_assign_role_category text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid; v_agency uuid;
  pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;

  SELECT p.agency_id, p.team_member_id, p.candidate_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;

  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NULL THEN RETURN false; END IF;

  IF p_assigned_to = v_me THEN RETURN true; END IF;

  IF p_assign_role_category IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.team tm
       WHERE tm.id = v_me AND tm.role_category = p_assign_role_category) THEN
    RETURN true;
  END IF;

  IF p_owner_kind = 'team' AND pl.team_member_id IS DISTINCT FROM v_me THEN
    RETURN true;
  END IF;

  IF p_auto_source = 'references' AND pl.candidate_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.hiring_reference_callers(pl.candidate_id) k
                 WHERE k.team_member_id = v_me) THEN
    RETURN true;
  END IF;

  IF pl.team_member_id = v_me AND EXISTS (
       SELECT 1 FROM public.onboarding_phases ph
       WHERE ph.agency_id = pl.agency_id AND ph.phase = p_phase AND ph.stage = 'ramp') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

DROP POLICY IF EXISTS tos_select ON public.team_onboarding_steps;
CREATE POLICY tos_select ON public.team_onboarding_steps FOR SELECT
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind, assign_role_category));
DROP POLICY IF EXISTS tos_update ON public.team_onboarding_steps;
CREATE POLICY tos_update ON public.team_onboarding_steps FOR UPDATE
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind, assign_role_category))
  WITH CHECK (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind, assign_role_category));

CREATE OR REPLACE FUNCTION public.onboarding_can_see_plan(p_plan_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_me uuid; v_agency uuid; pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  SELECT p.agency_id, p.team_member_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;
  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NOT NULL AND pl.team_member_id = v_me THEN RETURN true; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.team_onboarding_steps s
    WHERE s.plan_id = p_plan_id
      AND public.onboarding_can_see_step(s.plan_id, s.phase, s.assigned_to, s.auto_source, s.owner_kind, s.assign_role_category));
END;
$function$;

DROP FUNCTION IF EXISTS public.onboarding_can_see_step(uuid, integer, uuid, text, text);

-- Finishing a step closes its group tasks too; reopening it reopens them.
CREATE OR REPLACE FUNCTION public.sync_onboarding_step_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.completed_at IS NOT NULL AND OLD.completed_at IS NULL THEN
    UPDATE public.tasks SET status = 'completed', completed_at = NEW.completed_at, updated_at = now()
    WHERE (id = NEW.task_id OR (related_id = NEW.id AND created_by = 'onboarding_group'))
      AND status <> 'completed';
  ELSIF NEW.completed_at IS NULL AND OLD.completed_at IS NOT NULL THEN
    UPDATE public.tasks SET status = 'open', completed_at = NULL, updated_at = now()
    WHERE (id = NEW.task_id OR (related_id = NEW.id AND created_by = 'onboarding_group'))
      AND status = 'completed';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_task_tick_syncs_onboarding_step ON public.tasks;
CREATE TRIGGER trg_task_tick_syncs_onboarding_step
  AFTER UPDATE OF status ON public.tasks
  FOR EACH ROW
  WHEN (new.created_by IN ('onboarding_plan', 'onboarding_team_card', 'onboarding_group'))
  EXECUTE FUNCTION public.task_tick_syncs_onboarding_step();

-- ─── template data ─────────────────────────────────────────────────────
SELECT set_config('app.onboarding_template_sync', 'off', true);

-- Paperwork: the list is the site forms, each one linked. Peter's wording kept.
UPDATE public.onboarding_step_templates
   SET widget = NULL,
       substeps = '["[Payroll and Bio](/development?area=forms&form=combined_onboarding)", "[W-4](/development?area=forms&form=w4)", "[I-9](/development?area=forms&form=i9)", "[State Farm Annual Certification](/development?area=forms&form=annual_certification)", "[Non-Compete](/development?area=forms&form=non_compete)", "[Handbook](/development?area=forms&form=handbook_ack)"]'::jsonb,
       description = 'Each one ticks itself when the form is done.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_paperwork_pack';

-- Take Headshot: bottom of the first Setup column; Alvi and the retention team.
UPDATE public.onboarding_step_templates t
   SET track = c.track, track_order = c.track_order,
       sort_order = c.max_sort + 10,
       assign_role_category = 'Retention'
  FROM (SELECT track, track_order, max(sort_order) AS max_sort
        FROM public.onboarding_step_templates
        WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 50 AND track_order = 1
          AND template_key <> 'take_headshot'
        GROUP BY track, track_order) c
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'take_headshot';

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
SELECT public.onboarding_sync_form_steps(NULL);
