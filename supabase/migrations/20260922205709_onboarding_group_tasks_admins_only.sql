-- Tasks are only for the owner and managers (Peter and Marie). Onboarding group
-- steps must not create task rows for anyone else on the team.
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
      AND u.role IN ('owner', 'manager')
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
