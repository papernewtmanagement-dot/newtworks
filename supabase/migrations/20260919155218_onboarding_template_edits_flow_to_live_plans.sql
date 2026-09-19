-- One rule for "which template rows belong to this plan". Every caller uses it,
-- so a plan can never be built one way and re-synced another.
CREATE OR REPLACE FUNCTION public.onboarding_templates_for_plan(p_plan_id uuid)
RETURNS SETOF public.onboarding_step_templates
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT t.*
  FROM public.team_onboarding_plans p
  JOIN public.onboarding_step_templates t
    ON t.agency_id = p.agency_id
   AND t.is_active = true
   AND (t.applies_to_roles           IS NULL OR p.role_snapshot          = ANY (t.applies_to_roles))
   AND (t.applies_to_role_categories IS NULL OR p.role_category_snapshot = ANY (t.applies_to_role_categories))
   AND (t.applies_to_role_levels     IS NULL OR p.role_level_snapshot    = ANY (t.applies_to_role_levels))
  WHERE p.id = p_plan_id;
$$;

-- Bring one live plan back in line with the templates.
-- Never touches completed_at, completed_by, notes, auto_summary or opened_notified_at,
-- so ticked boxes survive. Sub-item ticks survive too; only labels the template
-- dropped are pruned out of substeps_done.
CREATE OR REPLACE FUNCTION public.onboarding_sync_plan(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  p               record;
  r               record;
  v_subject       text;
  v_gone          uuid[] := '{}';
  v_moved         uuid[] := '{}';
  v_added         int := 0;
  v_changed       int := 0;
  v_removed       int := 0;
  v_tasks         int := 0;
  v_owner_user_id uuid;
  v_task_id       uuid;
  v_due           date;
  v_title         text;
  v_desc          text;
BEGIN
  SELECT * INTO p FROM public.team_onboarding_plans WHERE id = p_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'onboarding plan % not found', p_plan_id;
  END IF;

  -- A finished or archived plan is a record of what happened. Leave it alone.
  IF p.status NOT IN ('active','paused') THEN
    RETURN jsonb_build_object('plan_id', p_plan_id, 'skipped', p.status);
  END IF;

  IF p.team_member_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(TRIM(COALESCE(nickname, first_name) || ' ' || COALESCE(last_name,'')), ''), 'New hire')
      INTO v_subject FROM public.team WHERE id = p.team_member_id;
  ELSE
    SELECT COALESCE(NULLIF(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), ''), candidate_name, 'Candidate')
      INTO v_subject FROM public.hiring_candidates WHERE id = p.candidate_id;
  END IF;
  v_subject := COALESCE(v_subject, 'New hire');

  -- Note which steps are about to move phase, so their task due date can follow.
  SELECT COALESCE(array_agg(s.id), '{}') INTO v_moved
  FROM public.team_onboarding_steps s
  JOIN public.onboarding_templates_for_plan(p_plan_id) t ON t.template_key = s.template_key
  WHERE s.plan_id = p_plan_id AND s.phase IS DISTINCT FROM t.phase;

  -- 1. Steps whose template was deleted, switched off, or no longer fits this role.
  --    A ticked step is history and stays put. An open one goes, with its task.
  SELECT COALESCE(array_agg(s.id), '{}') INTO v_gone
  FROM public.team_onboarding_steps s
  WHERE s.plan_id = p_plan_id
    AND s.template_key IS NOT NULL
    AND s.completed_at IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.onboarding_templates_for_plan(p_plan_id) t
      WHERE t.template_key = s.template_key);

  IF array_length(v_gone, 1) IS NOT NULL THEN
    DELETE FROM public.tasks
    WHERE id IN (SELECT task_id FROM public.team_onboarding_steps
                 WHERE id = ANY (v_gone) AND task_id IS NOT NULL);
    DELETE FROM public.team_onboarding_steps WHERE id = ANY (v_gone);
    v_removed := array_length(v_gone, 1);
  END IF;

  -- 2. Templates added since the plan was built. They arrive unticked.
  INSERT INTO public.team_onboarding_steps (
    plan_id, template_key, title, description, phase, category,
    source_manual_id, source_anchor, sort_order, is_required,
    required_topic_set_id, required_mode_key,
    substeps, substeps_done, owner_kind, assigned_to, track, blocked_by, track_order, auto_source
  )
  SELECT
    p_plan_id, t.template_key, t.title, t.description, t.phase, t.category,
    t.source_manual_id, t.source_anchor, t.sort_order, t.is_required,
    t.required_topic_set_id, t.required_mode_key,
    t.substeps,
    CASE WHEN t.substeps IS NULL THEN NULL ELSE '[]'::jsonb END,
    t.owner_kind, t.assigned_to, t.track, t.blocked_by, t.track_order, t.auto_source
  FROM public.onboarding_templates_for_plan(p_plan_id) t
  WHERE NOT EXISTS (
    SELECT 1 FROM public.team_onboarding_steps s
    WHERE s.plan_id = p_plan_id AND s.template_key = t.template_key);
  GET DIAGNOSTICS v_added = ROW_COUNT;

  -- 3. Wording, phase, order, owner, sub-items: pull the template's version through.
  UPDATE public.team_onboarding_steps s
  SET title                 = t.title,
      description           = t.description,
      phase                 = t.phase,
      category              = t.category,
      source_manual_id      = t.source_manual_id,
      source_anchor         = t.source_anchor,
      sort_order            = t.sort_order,
      is_required           = t.is_required,
      owner_kind            = t.owner_kind,
      assigned_to           = t.assigned_to,
      track                 = t.track,
      blocked_by            = t.blocked_by,
      track_order           = t.track_order,
      auto_source           = t.auto_source,
      required_topic_set_id = t.required_topic_set_id,
      required_mode_key     = t.required_mode_key,
      -- Steps that fill themselves in from elsewhere own their own sub-items.
      substeps = CASE WHEN COALESCE(s.auto_source, t.auto_source) IS NOT NULL
                      THEN s.substeps ELSE t.substeps END,
      substeps_done = CASE
        WHEN COALESCE(s.auto_source, t.auto_source) IS NOT NULL THEN s.substeps_done
        WHEN t.substeps IS NULL THEN NULL
        ELSE COALESCE((
               SELECT jsonb_agg(d)
               FROM jsonb_array_elements(
                      CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                           THEN s.substeps_done ELSE '[]'::jsonb END) d
               WHERE d #>> '{}' = ANY (public.onboarding_substep_labels(t.substeps))
             ), '[]'::jsonb)
      END,
      updated_at = now()
  FROM public.onboarding_templates_for_plan(p_plan_id) t
  WHERE s.plan_id = p_plan_id
    AND s.template_key = t.template_key
    AND (
      (s.title, s.description, s.phase, s.category, s.source_manual_id, s.source_anchor,
       s.sort_order, s.is_required, s.owner_kind, s.assigned_to, s.track, s.blocked_by,
       s.track_order, s.auto_source, s.required_topic_set_id, s.required_mode_key)
      IS DISTINCT FROM
      (t.title, t.description, t.phase, t.category, t.source_manual_id, t.source_anchor,
       t.sort_order, t.is_required, t.owner_kind, t.assigned_to, t.track, t.blocked_by,
       t.track_order, t.auto_source, t.required_topic_set_id, t.required_mode_key)
      OR (COALESCE(s.auto_source, t.auto_source) IS NULL AND s.substeps IS DISTINCT FROM t.substeps)
    );
  GET DIAGNOSTICS v_changed = ROW_COUNT;

  -- 4. Keep the linked task in step with the step. Only steps that carry an owner
  --    have one, so only those are worth walking.
  FOR r IN
    SELECT s.id, s.title, s.description, s.assigned_to, s.phase, s.task_id, ph.name AS phase_name
    FROM public.team_onboarding_steps s
    LEFT JOIN public.onboarding_phases ph
      ON ph.agency_id = p.agency_id AND ph.phase = s.phase
    WHERE s.plan_id = p_plan_id
      AND (s.assigned_to IS NOT NULL OR s.task_id IS NOT NULL)
  LOOP
    -- Owner removed from the template: the task goes with it.
    IF r.assigned_to IS NULL THEN
      IF r.task_id IS NOT NULL THEN
        DELETE FROM public.tasks WHERE id = r.task_id;
        UPDATE public.team_onboarding_steps SET task_id = NULL WHERE id = r.id;
        v_tasks := v_tasks + 1;
      END IF;
      CONTINUE;
    END IF;

    SELECT u.id INTO v_owner_user_id
    FROM public.users u WHERE u.team_member_id = r.assigned_to LIMIT 1;

    v_title := 'Onboarding — ' || v_subject || ': ' || r.title;
    v_desc  := COALESCE(r.description, '')
               || CASE WHEN r.phase_name IS NULL THEN '' ELSE E'\n\nPhase: ' || r.phase_name END;

    IF r.task_id IS NULL THEN
      -- Due when the phase opens, not when the person starts.
      v_due := GREATEST(
                 CURRENT_DATE,
                 COALESCE(public.onboarding_phase_opens_on(p.agency_id, r.phase, p.start_date),
                          COALESCE(p.start_date, CURRENT_DATE)));

      INSERT INTO public.tasks (
        agency_id, title, description, assigned_to, task_category, task_type,
        status, due_date, related_id, created_by
      ) VALUES (
        p.agency_id, v_title, v_desc, v_owner_user_id, 'admin', 'task',
        'open', v_due, r.id, 'onboarding_plan'
      ) RETURNING id INTO v_task_id;

      UPDATE public.team_onboarding_steps SET task_id = v_task_id WHERE id = r.id;
      v_tasks := v_tasks + 1;
    ELSE
      UPDATE public.tasks tk
      SET title       = v_title,
          description = v_desc,
          assigned_to = v_owner_user_id,
          -- The due date only moves when the step actually changed phase.
          due_date    = CASE WHEN r.id = ANY (v_moved)
                             THEN GREATEST(
                                    CURRENT_DATE,
                                    COALESCE(public.onboarding_phase_opens_on(p.agency_id, r.phase, p.start_date),
                                             COALESCE(p.start_date, CURRENT_DATE)))
                             ELSE tk.due_date END,
          updated_at  = now()
      WHERE tk.id = r.task_id
        AND ((tk.title, tk.description, tk.assigned_to)
             IS DISTINCT FROM (v_title, v_desc, v_owner_user_id)
             OR r.id = ANY (v_moved));
      IF FOUND THEN v_tasks := v_tasks + 1; END IF;
    END IF;

    v_owner_user_id := NULL;
  END LOOP;

  RETURN jsonb_build_object(
    'plan_id', p_plan_id, 'added', v_added, 'updated', v_changed,
    'removed', v_removed, 'tasks_touched', v_tasks);
END;
$$;

-- Every plan still running.
CREATE OR REPLACE FUNCTION public.onboarding_sync_open_plans(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE r record; v_out jsonb := '[]'::jsonb;
BEGIN
  FOR r IN
    SELECT id FROM public.team_onboarding_plans
    WHERE agency_id = p_agency_id AND status IN ('active','paused')
    ORDER BY created_at
  LOOP
    v_out := v_out || jsonb_build_array(public.onboarding_sync_plan(r.id));
  END LOOP;
  RETURN jsonb_build_object('plans', jsonb_array_length(v_out), 'detail', v_out);
END;
$$;

-- Edit a template, every live plan follows. Statement level so a bulk edit
-- syncs once, not once per row.
CREATE OR REPLACE FUNCTION public.onboarding_templates_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF COALESCE(current_setting('app.onboarding_template_sync', true), '') = 'off' THEN
    RETURN NULL;
  END IF;
  PERFORM public.onboarding_sync_open_plans();
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_onboarding_templates_sync_plans ON public.onboarding_step_templates;
CREATE TRIGGER trg_onboarding_templates_sync_plans
AFTER INSERT OR UPDATE OR DELETE ON public.onboarding_step_templates
FOR EACH STATEMENT EXECUTE FUNCTION public.onboarding_templates_changed();

COMMENT ON FUNCTION public.onboarding_sync_plan(uuid) IS
'Reconciles one live onboarding plan against the step templates. Adds new template
items, updates wording/phase/order/owner/sub-items on existing ones, and removes
open items whose template is gone. Completed steps and every ticked box are left
alone. Called by create_onboarding_plan and by the template-edit trigger.';

