-- Only the owner and managers (Peter and Marie) get tasks. Anyone else a step
-- is assigned to, by name, by group, or on a team card, gets a notice and
-- handles it on the Development tab (Onboarding).

CREATE OR REPLACE FUNCTION public.user_gets_tasks(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.users u
                 WHERE u.id = p_user_id AND u.role IN ('owner', 'manager'));
$function$;

-- 1. Named step owner: task only for Peter or Marie.
CREATE OR REPLACE FUNCTION public.onboarding_sync_plan(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  v_subject := public.onboarding_plan_subject_name(p_plan_id);

  -- Note which steps are about to move phase, so their task due date can follow.
  SELECT COALESCE(array_agg(s.id), '{}') INTO v_moved
  FROM public.team_onboarding_steps s
  JOIN public.onboarding_templates_for_plan(p_plan_id) t ON t.template_key = s.template_key
  WHERE s.plan_id = p_plan_id
    AND (s.phase IS DISTINCT FROM t.phase
         OR s.unlocks_on IS DISTINCT FROM public.onboarding_unlock_date(t.unlock_rule, p.start_date));

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
    substeps, substeps_done, owner_kind, assigned_to, track, blocked_by, track_order, auto_source,
    unlock_rule, unlocks_on, widget, assign_role_category
  )
  SELECT
    p_plan_id, t.template_key, t.title, t.description, t.phase, t.category,
    t.source_manual_id, t.source_anchor, t.sort_order, t.is_required,
    t.required_topic_set_id, t.required_mode_key,
    public.onboarding_fill_substeps(t.substeps, p_plan_id),
    CASE WHEN public.onboarding_fill_substeps(t.substeps, p_plan_id) IS NULL THEN NULL ELSE '[]'::jsonb END,
    t.owner_kind, t.assigned_to, t.track, t.blocked_by, t.track_order, t.auto_source,
    t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date), t.widget, t.assign_role_category
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
      unlock_rule           = t.unlock_rule,
      widget                = t.widget,
      assign_role_category  = t.assign_role_category,
      unlocks_on            = public.onboarding_unlock_date(t.unlock_rule, p.start_date),
      required_topic_set_id = t.required_topic_set_id,
      required_mode_key     = t.required_mode_key,
      -- Steps that fill themselves in from elsewhere own their own sub-items.
      substeps = CASE WHEN COALESCE(s.auto_source, t.auto_source) IS NOT NULL
                      THEN s.substeps ELSE public.onboarding_fill_substeps(t.substeps, p_plan_id) END,
      substeps_done = CASE
        WHEN COALESCE(s.auto_source, t.auto_source) IS NOT NULL THEN s.substeps_done
        WHEN public.onboarding_fill_substeps(t.substeps, p_plan_id) IS NULL THEN NULL
        ELSE COALESCE((
               SELECT jsonb_agg(d)
               FROM jsonb_array_elements(
                      CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                           THEN s.substeps_done ELSE '[]'::jsonb END) d
               WHERE d #>> '{}' = ANY (public.onboarding_substep_labels(public.onboarding_fill_substeps(t.substeps, p_plan_id)))
             ), '[]'::jsonb)
      END,
      updated_at = now()
  FROM public.onboarding_templates_for_plan(p_plan_id) t
  WHERE s.plan_id = p_plan_id
    AND s.template_key = t.template_key
    AND (
      (s.title, s.description, s.phase, s.category, s.source_manual_id, s.source_anchor,
       s.sort_order, s.is_required, s.owner_kind, s.assigned_to, s.track, s.blocked_by,
       s.track_order, s.auto_source, s.required_topic_set_id, s.required_mode_key,
       s.unlock_rule, s.unlocks_on, s.widget, s.assign_role_category)
      IS DISTINCT FROM
      (t.title, t.description, t.phase, t.category, t.source_manual_id, t.source_anchor,
       t.sort_order, t.is_required, t.owner_kind, t.assigned_to, t.track, t.blocked_by,
       t.track_order, t.auto_source, t.required_topic_set_id, t.required_mode_key,
       t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date), t.widget, t.assign_role_category)
      OR (COALESCE(s.auto_source, t.auto_source) IS NULL AND s.substeps IS DISTINCT FROM public.onboarding_fill_substeps(t.substeps, p_plan_id))
    );
  GET DIAGNOSTICS v_changed = ROW_COUNT;

  -- 4. Keep the linked task in step with the step. Only steps that carry an owner
  --    have one, so only those are worth walking. Only Peter and Marie get tasks;
  --    anyone else is notified and works the step on the Development tab.
  FOR r IN
    SELECT s.id, s.title, s.description, s.assigned_to, s.phase, s.task_id, s.unlocks_on, ph.name AS phase_name
    FROM public.team_onboarding_steps s
    LEFT JOIN public.onboarding_phases ph
      ON ph.agency_id = p.agency_id AND ph.phase = s.phase
    WHERE s.plan_id = p_plan_id
      AND (s.assigned_to IS NOT NULL OR s.task_id IS NOT NULL)
  LOOP
    SELECT u.id INTO v_owner_user_id
    FROM public.users u WHERE u.team_member_id = r.assigned_to LIMIT 1;

    -- No owner, or an owner who does not get tasks: no open task for this step.
    IF r.assigned_to IS NULL OR NOT public.user_gets_tasks(v_owner_user_id) THEN
      IF r.task_id IS NOT NULL THEN
        DELETE FROM public.tasks WHERE id = r.task_id AND status <> 'completed';
        UPDATE public.team_onboarding_steps SET task_id = NULL WHERE id = r.id;
        v_tasks := v_tasks + 1;
      END IF;
      v_owner_user_id := NULL;
      CONTINUE;
    END IF;

    v_title := 'Onboarding — ' || v_subject || ': ' || r.title;
    v_desc  := COALESCE(r.description, '')
               || CASE WHEN r.phase_name IS NULL THEN '' ELSE E'\n\nPhase: ' || r.phase_name END;

    IF r.task_id IS NULL THEN
      -- Due when the phase opens, not when the person starts.
      v_due := public.onboarding_step_due_on(p.agency_id, r.phase, p.start_date, r.unlocks_on);

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
                             THEN public.onboarding_step_due_on(p.agency_id, r.phase, p.start_date, r.unlocks_on)
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

  PERFORM public.onboarding_sync_group_tasks(p_plan_id);

  RETURN jsonb_build_object(
    'plan_id', p_plan_id, 'added', v_added, 'updated', v_changed,
    'removed', v_removed, 'tasks_touched', v_tasks);
END;
$function$;

-- 2. Group steps: tasks only for Peter or Marie in the group. Open group tasks
--    held by anyone else go.
CREATE OR REPLACE FUNCTION public.onboarding_sync_group_tasks(p_plan_id uuid)
 RETURNS integer
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

  -- Open group tasks for people no longer in the group, on steps that dropped
  -- their group, or held by someone who does not get tasks, go.
  DELETE FROM public.tasks t
  USING public.team_onboarding_steps st
  WHERE st.plan_id = p_plan_id
    AND t.related_id = st.id
    AND t.created_by = 'onboarding_group'
    AND t.status <> 'completed'
    AND (st.assign_role_category IS NULL
         OR NOT public.user_gets_tasks(t.assigned_to)
         OR NOT EXISTS (
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
      AND public.user_gets_tasks(u.id)
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

-- 3. Team cards: everyone still gets the email; only Peter or Marie get a task.
CREATE OR REPLACE FUNCTION public.onboarding_team_card_notices(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s        record;
  tm       record;
  v_base   text;
  v_link   text;
  v_labels text[];
  v_user   uuid;
  v_tasks_ok boolean;
  v_first  text;
  v_email  text;
  v_html   text;
  v_cards  int := 0;
  v_mails  int := 0;
  v_tasks  int := 0;
BEGIN
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');

  FOR s IN
    SELECT st.id, st.title, st.description, st.plan_id, st.substeps, p.start_date, p.team_member_id,
           COALESCE(
             NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name, '')), ''),
             NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''),
             c.candidate_name, 'the new hire') AS subject_name
    FROM public.team_onboarding_steps st
    JOIN public.team_onboarding_plans p ON p.id = st.plan_id
    LEFT JOIN public.team t ON t.id = p.team_member_id
    LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
    WHERE p.agency_id = p_agency_id
      AND st.owner_kind = 'team'
      AND st.opened_notified_at IS NULL
      AND public.onboarding_step_is_open(st.id)
  LOOP
    v_link   := v_base || '/onboarding?plan=' || s.plan_id::text;
    v_labels := public.onboarding_substep_labels(s.substeps);

    FOR tm IN
      SELECT x.*
      FROM public.team x
      WHERE x.agency_id = p_agency_id
        AND x.is_active IS TRUE
        AND x.archived_at IS NULL
        AND COALESCE(x.is_test_user, false) = false
        AND x.id IS DISTINCT FROM s.team_member_id
        AND public.onboarding_team_label(x) = ANY (v_labels)
    LOOP
      v_first := COALESCE(NULLIF(TRIM(COALESCE(tm.nickname, tm.first_name)), ''), 'there');
      v_email := COALESCE(NULLIF(tm.email_personal, ''), NULLIF(tm.email_sf, ''));

      SELECT u.id INTO v_user FROM public.users u WHERE u.team_member_id = tm.id LIMIT 1;
      v_tasks_ok := public.user_gets_tasks(v_user);
      IF v_tasks_ok AND NOT EXISTS (
           SELECT 1 FROM public.tasks k
           WHERE k.related_id = s.id AND k.created_by = 'onboarding_team_card' AND k.assigned_to = v_user) THEN
        INSERT INTO public.tasks (agency_id, title, description, assigned_to, task_category, task_type,
                                  status, due_date, related_id, created_by)
        VALUES (p_agency_id, 'Onboarding — ' || s.subject_name || ': ' || s.title,
                COALESCE(s.description, '') || E'\n\nTick your name on the card when it is done: ' || v_link,
                v_user, 'admin', 'task', 'open', CURRENT_DATE, s.id, 'onboarding_team_card');
        v_tasks := v_tasks + 1;
      END IF;
      v_user := NULL;

      IF v_email IS NOT NULL THEN
        v_html := '<p>Hi ' || v_first || ',</p>' ||
                  '<p><b>' || s.subject_name || '</b> has State Farm system access now' ||
                  CASE WHEN s.start_date IS NULL THEN '' ELSE ' and starts ' || to_char(s.start_date, 'Dy Mon FMDD') END ||
                  '. Please add them to your Outlook and your Jabber.</p>' ||
                  CASE WHEN v_tasks_ok
                       THEN '<p>Then tick your name on the <b>' || s.title || '</b> card so we know it is done: ' ||
                            '<a href="' || v_link || '">Open ' || s.subject_name || '''s onboarding in Newtworks</a></p>' ||
                            '<p>It is on your task list too. Ticking your name closes it.</p>'
                       ELSE '<p>Then tick your name on the <b>' || s.title || '</b> card, on the Development tab in Newtworks, so we know it is done: ' ||
                            '<a href="' || v_link || '">Open ' || s.subject_name || '''s onboarding</a></p>'
                  END;
        PERFORM public.composio_send_email(p_agency_id, v_email,
          s.subject_name || ' onboarding — add them to your Outlook and Jabber', v_html);
        v_mails := v_mails + 1;
      END IF;
    END LOOP;

    UPDATE public.team_onboarding_steps SET opened_notified_at = now() WHERE id = s.id;
    v_cards := v_cards + 1;
  END LOOP;

  RETURN jsonb_build_object('cards', v_cards, 'emails', v_mails, 'tasks', v_tasks);
END;
$function$;

-- 4. Step-open notices: go to the named owner AND everyone in the step's group.
--    Peter and Marie are pointed at their task list; everyone else at the
--    Development tab.
CREATE OR REPLACE FUNCTION public.onboarding_open_step_notices(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  g        record;
  v_titles text[];
  v_ids    uuid[];
  v_tg     text;
  v_html   text;
  v_line   text;
  v_where  text;
  v_base   text;
  v_link   text;
  v_people int := 0;
  v_steps  int := 0;
  v_emails int := 0;
BEGIN
  PERFORM public.onboarding_sync_reference_steps(p_agency_id);
  PERFORM public.onboarding_team_card_notices(p_agency_id);
  PERFORM public.onboarding_sync_form_steps(NULL);

  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');

  FOR g IN
    WITH open_steps AS (
      SELECT s.id, s.title, s.assigned_to, s.assign_role_category, s.plan_id, p.start_date,
             p.team_member_id AS subject_tm,
             COALESCE(
               NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name, '')), ''),
               NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''),
               c.candidate_name, 'the new hire') AS subject_name
      FROM public.team_onboarding_steps s
      JOIN public.team_onboarding_plans p ON p.id = s.plan_id
      LEFT JOIN public.team t ON t.id = p.team_member_id
      LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
      WHERE p.agency_id = p_agency_id
        AND p.status = 'active'
        AND (s.assigned_to IS NOT NULL OR s.assign_role_category IS NOT NULL)
        AND s.opened_notified_at IS NULL
        AND public.onboarding_step_is_open(s.id)
    ),
    recipients AS (
      SELECT o.id, o.title, o.plan_id, o.start_date, o.subject_name, o.assigned_to AS recipient
      FROM open_steps o
      WHERE o.assigned_to IS NOT NULL
      UNION
      SELECT o.id, o.title, o.plan_id, o.start_date, o.subject_name, x.id
      FROM open_steps o
      JOIN public.team x
        ON x.agency_id = p_agency_id
       AND x.role_category = o.assign_role_category
       AND x.is_active IS TRUE AND x.archived_at IS NULL
       AND COALESCE(x.is_test_user, false) = false
       AND x.id IS DISTINCT FROM o.subject_tm
      WHERE o.assign_role_category IS NOT NULL
    )
    SELECT r.recipient, r.plan_id, r.subject_name, r.start_date,
           COALESCE(NULLIF(TRIM(COALESCE(tm.nickname, tm.first_name)), ''), 'there') AS first_name,
           COALESCE(NULLIF(tm.email_personal, ''), NULLIF(tm.email_sf, '')) AS email,
           EXISTS (SELECT 1 FROM public.users u
                   WHERE u.team_member_id = tm.id AND public.user_gets_tasks(u.id)) AS gets_tasks,
           array_agg(r.title ORDER BY r.title) AS titles,
           array_agg(r.id) AS step_ids
    FROM recipients r
    JOIN public.team tm ON tm.id = r.recipient
    GROUP BY r.recipient, r.plan_id, r.subject_name, r.start_date, tm.id,
             tm.nickname, tm.first_name, tm.email_personal, tm.email_sf
  LOOP
    v_titles := g.titles;
    v_ids    := g.step_ids;
    v_link   := v_base || '/onboarding?plan=' || g.plan_id::text;
    v_where  := CASE WHEN g.gets_tasks THEN 'They are on your task list in Newtworks'
                     ELSE 'Handle them on the Development tab in Newtworks' END;

    v_line := CASE WHEN array_length(v_titles, 1) = 1
                   THEN '1 onboarding step is ready for you'
                   ELSE array_length(v_titles, 1)::text || ' onboarding steps are ready for you' END;

    v_tg := '<b>' || g.first_name || ' — ' || v_line || '</b>' || E'\n' ||
            'Onboarding for ' || g.subject_name ||
            CASE WHEN g.start_date IS NULL THEN ''
                 ELSE ', starting ' || to_char(g.start_date, 'Dy Mon FMDD') END || E'\n\n' ||
            (SELECT string_agg('• ' || t, E'\n') FROM unnest(v_titles) t) || E'\n\n' ||
            v_where || ': ' || v_link;

    PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

    IF g.email IS NOT NULL THEN
      v_html := '<p>Hi ' || g.first_name || ',</p>' ||
                '<p>' || v_line || ' on the onboarding schedule for <b>' || g.subject_name || '</b>' ||
                CASE WHEN g.start_date IS NULL THEN ''
                     ELSE ', who starts ' || to_char(g.start_date, 'Dy Mon FMDD') END || '.</p><ul>' ||
                (SELECT string_agg('<li>' || t || '</li>', '') FROM unnest(v_titles) t) ||
                '</ul>' ||
                CASE WHEN g.gets_tasks
                     THEN '<p>They are on your task list, and the whole checklist is here: '
                     ELSE '<p>Handle them on the Development tab in Newtworks and tick each one off when it is done: '
                END ||
                '<a href="' || v_link || '">Open ' || g.subject_name || '''s onboarding in Newtworks</a></p>' ||
                '<p>Nothing else on that checklist needs you yet. Anything dated later will turn up in another note when it does.</p>';

      PERFORM public.composio_send_email(
        p_agency_id, g.email,
        g.subject_name || ' onboarding — ' || v_line, v_html);
      v_emails := v_emails + 1;
    END IF;

    UPDATE public.team_onboarding_steps
    SET opened_notified_at = now()
    WHERE id = ANY (v_ids);

    v_people := v_people + 1;
    v_steps  := v_steps + array_length(v_titles, 1);
  END LOOP;

  RETURN jsonb_build_object('people', v_people, 'steps', v_steps, 'emails', v_emails);
END;
$function$;
