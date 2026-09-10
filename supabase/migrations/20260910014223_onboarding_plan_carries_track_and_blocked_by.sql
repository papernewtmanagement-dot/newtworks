CREATE OR REPLACE FUNCTION public.create_onboarding_plan(
  p_team_member_id uuid DEFAULT NULL,
  p_candidate_id   uuid DEFAULT NULL,
  p_role           text DEFAULT NULL,
  p_role_category  text DEFAULT NULL,
  p_role_level     text DEFAULT NULL,
  p_start_date     date DEFAULT CURRENT_DATE,
  p_target_end_date date DEFAULT NULL,
  p_notes          text DEFAULT NULL
) RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id       uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_role            text := p_role;
  v_role_category   text := p_role_category;
  v_role_level      text := p_role_level;
  v_plan_id         uuid;
  v_step_count      int;
  v_creator_user_id uuid;
  v_subject_name    text;
  r                 record;
  v_task_id         uuid;
  v_owner_user_id   uuid;
  v_due             date;
BEGIN
  IF p_team_member_id IS NULL AND p_candidate_id IS NULL THEN
    RAISE EXCEPTION 'Pass either a team member or a candidate.';
  END IF;

  IF p_team_member_id IS NOT NULL THEN
    SELECT agency_id,
           COALESCE(p_role, role),
           COALESCE(p_role_category, role_category),
           COALESCE(p_role_level, role_level),
           COALESCE(NULLIF(TRIM(COALESCE(nickname, first_name) || ' ' || COALESCE(last_name,'')), ''), 'New hire')
    INTO v_agency_id, v_role, v_role_category, v_role_level, v_subject_name
    FROM public.team WHERE id = p_team_member_id;

    IF v_agency_id IS NULL THEN
      RAISE EXCEPTION 'team_member_id % not found', p_team_member_id;
    END IF;
  ELSE
    SELECT agency_id,
           COALESCE(NULLIF(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), ''), candidate_name, 'Candidate'),
           COALESCE(p_start_date, offer_start_date)
    INTO v_agency_id, v_subject_name, p_start_date
    FROM public.hiring_candidates WHERE id = p_candidate_id;

    IF v_agency_id IS NULL THEN
      RAISE EXCEPTION 'candidate_id % not found', p_candidate_id;
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.team_onboarding_plans
    WHERE status IN ('active','paused')
      AND ((p_team_member_id IS NOT NULL AND team_member_id = p_team_member_id)
        OR (p_candidate_id   IS NOT NULL AND candidate_id   = p_candidate_id))
  ) THEN
    RAISE EXCEPTION 'There is already an active or paused onboarding plan for %. Complete or archive it first.', v_subject_name;
  END IF;

  SELECT id INTO v_creator_user_id
  FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  INSERT INTO public.team_onboarding_plans (
    agency_id, team_member_id, candidate_id,
    role_snapshot, role_category_snapshot, role_level_snapshot,
    start_date, target_end_date, status, notes, created_by
  ) VALUES (
    v_agency_id, p_team_member_id, p_candidate_id,
    v_role, v_role_category, v_role_level,
    p_start_date, p_target_end_date, 'active', p_notes, v_creator_user_id
  ) RETURNING id INTO v_plan_id;

  INSERT INTO public.team_onboarding_steps (
    plan_id, template_key, title, description, phase, category,
    source_manual_id, source_anchor, sort_order, is_required,
    substeps, substeps_done, owner_kind, assigned_to, track, blocked_by
  )
  SELECT
    v_plan_id, t.template_key, t.title, t.description, t.phase, t.category,
    t.source_manual_id, t.source_anchor, t.sort_order, t.is_required,
    t.substeps,
    CASE WHEN t.substeps IS NULL THEN NULL ELSE '[]'::jsonb END,
    t.owner_kind, t.assigned_to, t.track, t.blocked_by
  FROM public.onboarding_step_templates t
  WHERE t.agency_id = v_agency_id
    AND t.is_active = true
    AND (t.applies_to_roles IS NULL OR v_role = ANY (t.applies_to_roles))
    AND (t.applies_to_role_categories IS NULL OR v_role_category = ANY (t.applies_to_role_categories))
    AND (t.applies_to_role_levels IS NULL OR v_role_level = ANY (t.applies_to_role_levels));

  GET DIAGNOSTICS v_step_count = ROW_COUNT;

  IF v_step_count = 0 THEN
    DELETE FROM public.team_onboarding_plans WHERE id = v_plan_id;
    RAISE EXCEPTION 'No matching templates for role=% role_category=% role_level=%. Aborted.',
      v_role, v_role_category, v_role_level;
  END IF;

  FOR r IN
    SELECT s.id, s.title, s.description, s.assigned_to, ph.name AS phase_name, ph.stage
    FROM public.team_onboarding_steps s
    LEFT JOIN public.onboarding_phases ph
      ON ph.agency_id = v_agency_id AND ph.phase = s.phase
    WHERE s.plan_id = v_plan_id
      AND s.assigned_to IS NOT NULL
  LOOP
    SELECT u.id INTO v_owner_user_id
    FROM public.users u WHERE u.team_member_id = r.assigned_to LIMIT 1;

    v_due := CASE
      WHEN r.stage IN ('offer','pre_start') THEN GREATEST(CURRENT_DATE, COALESCE(p_start_date, CURRENT_DATE) - 1)
      ELSE COALESCE(p_start_date, CURRENT_DATE)
    END;

    INSERT INTO public.tasks (
      agency_id, title, description, assigned_to, task_category, task_type,
      status, due_date, related_id, created_by
    ) VALUES (
      v_agency_id,
      'Onboarding — ' || v_subject_name || ': ' || r.title,
      COALESCE(r.description, '')
        || CASE WHEN r.phase_name IS NULL THEN '' ELSE E'\n\nPhase: ' || r.phase_name END,
      v_owner_user_id, 'admin', 'task',
      'open', v_due, r.id, 'onboarding_plan'
    ) RETURNING id INTO v_task_id;

    UPDATE public.team_onboarding_steps SET task_id = v_task_id WHERE id = r.id;
    v_owner_user_id := NULL;
  END LOOP;

  RETURN v_plan_id;
END;
$function$;
