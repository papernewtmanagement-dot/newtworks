-- Plan creation now builds the step list through the same function that keeps it
-- in line afterwards, so there is one copy of the template-to-step mapping.
CREATE OR REPLACE FUNCTION public.create_onboarding_plan(
  p_team_member_id uuid DEFAULT NULL::uuid,
  p_candidate_id   uuid DEFAULT NULL::uuid,
  p_role           text DEFAULT NULL::text,
  p_role_category  text DEFAULT NULL::text,
  p_role_level     text DEFAULT NULL::text,
  p_start_date     date DEFAULT CURRENT_DATE,
  p_notes          text DEFAULT NULL::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency_id       uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_role            text := p_role;
  v_role_category   text := p_role_category;
  v_role_level      text := p_role_level;
  v_plan_id         uuid;
  v_step_count      int;
  v_creator_user_id uuid;
  v_subject_name    text;
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
    start_date, status, notes, created_by
  ) VALUES (
    v_agency_id, p_team_member_id, p_candidate_id,
    v_role, v_role_category, v_role_level,
    p_start_date, 'active', p_notes, v_creator_user_id
  ) RETURNING id INTO v_plan_id;

  -- Fills the steps in and opens the owner tasks.
  PERFORM public.onboarding_sync_plan(v_plan_id);

  SELECT count(*) INTO v_step_count
  FROM public.team_onboarding_steps WHERE plan_id = v_plan_id;

  IF v_step_count = 0 THEN
    RAISE EXCEPTION 'No matching templates for role=% role_category=% role_level=%. Aborted.',
      v_role, v_role_category, v_role_level;
  END IF;

  PERFORM public.onboarding_sync_reference_steps(v_agency_id);

  RETURN v_plan_id;
END;
$$;

-- Ticking the task now reads sub-items the same way every other gate does.
-- The old version compared whole jsonb elements, so a grouped sub-item list
-- never counted as finished and the step stayed open.
CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  s         record;
  v_labels  text[];
  v_done    text[];
  v_missing int;
BEGIN
  IF NEW.related_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT id, completed_at, auto_source, substeps, substeps_done
  INTO s
  FROM public.team_onboarding_steps
  WHERE id = NEW.related_id;

  IF NOT FOUND OR s.auto_source IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND s.completed_at IS NULL THEN
    v_labels := public.onboarding_substep_labels(s.substeps);
    v_done   := public.onboarding_substep_labels(
                  CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                       THEN s.substeps_done ELSE '[]'::jsonb END);

    SELECT count(*) INTO v_missing
    FROM unnest(v_labels) l WHERE NOT (l = ANY (v_done));

    IF COALESCE(v_missing, 0) > 0 THEN
      RETURN NEW;   -- sub-items still open; the checklist stays the record
    END IF;

    UPDATE public.team_onboarding_steps
    SET completed_at = now(),
        completed_by = COALESCE(completed_by, NEW.assigned_to),
        updated_at   = now()
    WHERE id = s.id;

  ELSIF NEW.status <> 'completed' AND s.completed_at IS NOT NULL THEN
    UPDATE public.team_onboarding_steps
    SET completed_at = NULL,
        completed_by = NULL,
        updated_at   = now()
    WHERE id = s.id;
  END IF;

  RETURN NEW;
END;
$$;

