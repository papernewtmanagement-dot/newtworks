-- ============================================================================
-- Onboarding module — RPC to compile a plan from templates for a team member
-- ============================================================================
-- Reads the team member's role/role_category/role_level classifiers and
-- materializes matching onboarding_step_templates rows into team_onboarding_steps
-- as a per-plan snapshot. Templates with NULL role filters apply to everyone;
-- templates with non-NULL role_categories/roles/role_levels are included only
-- if the team member's corresponding classifier is in the array.
--
-- Snapshot semantics: at plan-creation time we COPY title/description/phase/
-- category/sort_order/is_required/source_manual_id/source_anchor into
-- team_onboarding_steps. Later template edits do NOT retro-mutate existing
-- plans — the plan owns its steps.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_onboarding_plan_from_templates(
  p_team_member_id  uuid,
  p_start_date      date DEFAULT CURRENT_DATE,
  p_target_end_date date DEFAULT NULL,
  p_notes           text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency_id       uuid;
  v_role            text;
  v_role_category   text;
  v_role_level      text;
  v_plan_id         uuid;
  v_step_count      int;
  v_creator_user_id uuid;
BEGIN
  -- Load team member classifiers
  SELECT agency_id, role, role_category, role_level
  INTO v_agency_id, v_role, v_role_category, v_role_level
  FROM public.team
  WHERE id = p_team_member_id;

  IF v_agency_id IS NULL THEN
    RAISE EXCEPTION 'team_member_id % not found', p_team_member_id;
  END IF;

  -- Guard: don't allow duplicate active plans for same person
  IF EXISTS (
    SELECT 1 FROM public.team_onboarding_plans
    WHERE team_member_id = p_team_member_id
      AND status IN ('active','paused')
  ) THEN
    RAISE EXCEPTION 'Team member % already has an active or paused onboarding plan. Complete or archive it first.', p_team_member_id;
  END IF;

  -- Resolve created_by from auth (nullable — service-role / SQL callers ok)
  SELECT id INTO v_creator_user_id
  FROM public.users
  WHERE auth_user_id = auth.uid()
  LIMIT 1;

  -- Create the plan with role snapshot for historical audit
  INSERT INTO public.team_onboarding_plans (
    agency_id, team_member_id,
    role_snapshot, role_category_snapshot, role_level_snapshot,
    start_date, target_end_date, status, notes, created_by
  ) VALUES (
    v_agency_id, p_team_member_id,
    v_role, v_role_category, v_role_level,
    p_start_date, p_target_end_date, 'active', p_notes, v_creator_user_id
  ) RETURNING id INTO v_plan_id;

  -- Materialize matching templates into steps
  INSERT INTO public.team_onboarding_steps (
    plan_id, template_key, title, description, phase, category,
    source_manual_id, source_anchor, sort_order, is_required
  )
  SELECT
    v_plan_id, t.template_key, t.title, t.description, t.phase, t.category,
    t.source_manual_id, t.source_anchor, t.sort_order, t.is_required
  FROM public.onboarding_step_templates t
  WHERE t.agency_id = v_agency_id
    AND t.is_active = true
    -- Role filter: NULL array = applies to everyone; else must contain member's role
    AND (t.applies_to_roles IS NULL OR v_role = ANY (t.applies_to_roles))
    AND (t.applies_to_role_categories IS NULL OR v_role_category = ANY (t.applies_to_role_categories))
    AND (t.applies_to_role_levels IS NULL OR v_role_level = ANY (t.applies_to_role_levels));

  GET DIAGNOSTICS v_step_count = ROW_COUNT;

  IF v_step_count = 0 THEN
    -- Roll back: a plan with zero steps is a config bug
    DELETE FROM public.team_onboarding_plans WHERE id = v_plan_id;
    RAISE EXCEPTION 'No matching templates for role=% role_category=% role_level=%. Aborted.',
      v_role, v_role_category, v_role_level;
  END IF;

  RETURN v_plan_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_onboarding_plan_from_templates(uuid,date,date,text) TO authenticated;

COMMENT ON FUNCTION public.create_onboarding_plan_from_templates(uuid,date,date,text) IS
  'Creates a team_onboarding_plans row and materializes matching onboarding_step_templates into team_onboarding_steps. Templates match when role/role_category/role_level filters are NULL (universal) or contain the team member''s classifier. Snapshot-copies title/description/phase/category/sort_order/is_required/source_manual_id/source_anchor. Guards against duplicate active plan for same person.';

-- ============================================================================
-- Drop legacy onboarding_checklists (0 rows, superseded by team_onboarding_plans/steps)
-- ============================================================================
DROP TABLE IF EXISTS public.onboarding_checklists CASCADE;
