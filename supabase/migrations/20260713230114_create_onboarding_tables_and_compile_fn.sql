-- ============================================================================
-- Onboarding module — schema + RLS + compile function
-- ============================================================================
-- 3 tables:
--   onboarding_step_templates — canonical step library with role applicability
--   team_onboarding_plans     — one per team_member × onboarding cycle
--   team_onboarding_steps     — denormalized per-plan step rows
-- 1 function:
--   compile_onboarding_plan(team_member_id, start_date) → plan_id
-- ============================================================================

-- Templates: the canonical step library
CREATE TABLE IF NOT EXISTS public.onboarding_step_templates (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                   UUID NOT NULL,
  template_key                TEXT NOT NULL,                        -- stable slug, agency-scoped
  title                       TEXT NOT NULL,
  description                 TEXT,
  phase                       INT NOT NULL,                         -- 0=pre_day1, 1=week1, 2=weeks_3_4, 3=weeks_5_8, 4=weeks_9_13, 5=week_14_plus
  category                    TEXT NOT NULL,                        -- licensing | documents | compliance | systems | training | physical_setup | role_specific
  source_manual_id            UUID REFERENCES public.manuals(id) ON DELETE SET NULL,
  source_anchor               TEXT,                                 -- optional anchor fragment
  applies_to_roles            TEXT[] DEFAULT NULL,                  -- NULL/empty = all roles
  applies_to_role_categories  TEXT[] DEFAULT NULL,                  -- NULL/empty = all role_categories
  applies_to_role_levels      TEXT[] DEFAULT NULL,                  -- NULL/empty = all role_levels
  is_required                 BOOLEAN NOT NULL DEFAULT true,
  sort_order                  INT NOT NULL DEFAULT 100,
  is_active                   BOOLEAN NOT NULL DEFAULT true,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, template_key),
  CHECK (phase BETWEEN 0 AND 5),
  CHECK (category IN ('licensing','documents','compliance','systems','training','physical_setup','role_specific'))
);

CREATE INDEX IF NOT EXISTS idx_onboarding_step_templates_agency_active
  ON public.onboarding_step_templates(agency_id, is_active, phase, sort_order);

-- Plans: one per team_member × cycle
CREATE TABLE IF NOT EXISTS public.team_onboarding_plans (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                   UUID NOT NULL,
  team_member_id              UUID NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  role_snapshot               TEXT,
  role_category_snapshot      TEXT,
  role_level_snapshot         TEXT,
  start_date                  DATE NOT NULL,
  target_end_date             DATE,
  status                      TEXT NOT NULL DEFAULT 'active',
  notes                       TEXT,
  created_by                  UUID,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (status IN ('active','paused','completed','abandoned'))
);

CREATE INDEX IF NOT EXISTS idx_team_onboarding_plans_agency_status
  ON public.team_onboarding_plans(agency_id, status, start_date);
CREATE INDEX IF NOT EXISTS idx_team_onboarding_plans_team_member
  ON public.team_onboarding_plans(team_member_id, status);

-- Steps: denormalized per-plan
CREATE TABLE IF NOT EXISTS public.team_onboarding_steps (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id                     UUID NOT NULL REFERENCES public.team_onboarding_plans(id) ON DELETE CASCADE,
  template_key                TEXT,                                 -- soft ref back to template (may be edited later)
  title                       TEXT NOT NULL,
  description                 TEXT,
  phase                       INT NOT NULL,
  category                    TEXT NOT NULL,
  source_manual_id            UUID REFERENCES public.manuals(id) ON DELETE SET NULL,
  source_anchor               TEXT,
  sort_order                  INT NOT NULL DEFAULT 100,
  is_required                 BOOLEAN NOT NULL DEFAULT true,
  completed_at                TIMESTAMPTZ,
  completed_by                UUID,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (phase BETWEEN 0 AND 5),
  CHECK (category IN ('licensing','documents','compliance','systems','training','physical_setup','role_specific'))
);

CREATE INDEX IF NOT EXISTS idx_team_onboarding_steps_plan_phase
  ON public.team_onboarding_steps(plan_id, phase, sort_order);
CREATE INDEX IF NOT EXISTS idx_team_onboarding_steps_completed
  ON public.team_onboarding_steps(plan_id, completed_at);

-- Updated-at trigger (shared trigger fn assumed to exist as touch_updated_at)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='touch_updated_at' AND pronamespace='public'::regnamespace) THEN
    CREATE OR REPLACE FUNCTION public.touch_updated_at() RETURNS TRIGGER
    LANGUAGE plpgsql AS $fn$
    BEGIN NEW.updated_at := NOW(); RETURN NEW; END $fn$;
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_touch_ost ON public.onboarding_step_templates;
CREATE TRIGGER trg_touch_ost BEFORE UPDATE ON public.onboarding_step_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_top ON public.team_onboarding_plans;
CREATE TRIGGER trg_touch_top BEFORE UPDATE ON public.team_onboarding_plans
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_tos ON public.team_onboarding_steps;
CREATE TRIGGER trg_touch_tos BEFORE UPDATE ON public.team_onboarding_steps
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============================================================================
-- RLS
-- ============================================================================

ALTER TABLE public.onboarding_step_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_onboarding_plans     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_onboarding_steps     ENABLE ROW LEVEL SECURITY;

-- Templates: any authenticated user in agency reads; admin (owner+manager) writes.
DROP POLICY IF EXISTS ost_read_agency ON public.onboarding_step_templates;
CREATE POLICY ost_read_agency ON public.onboarding_step_templates
  FOR SELECT
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

DROP POLICY IF EXISTS ost_admin_write ON public.onboarding_step_templates;
CREATE POLICY ost_admin_write ON public.onboarding_step_templates
  FOR ALL
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
  )
  WITH CHECK (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
  );

-- Plans: team member sees only their own plan; admin sees all in agency; admin writes.
DROP POLICY IF EXISTS top_select ON public.team_onboarding_plans;
CREATE POLICY top_select ON public.team_onboarding_plans
  FOR SELECT
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND (
      team_member_id IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid())
      OR EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
    )
  );

DROP POLICY IF EXISTS top_admin_write ON public.team_onboarding_plans;
CREATE POLICY top_admin_write ON public.team_onboarding_plans
  FOR ALL
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
  )
  WITH CHECK (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
  );

-- Steps: readable if the parent plan is readable. Team member can mark their own steps complete.
DROP POLICY IF EXISTS tos_select ON public.team_onboarding_steps;
CREATE POLICY tos_select ON public.team_onboarding_steps
  FOR SELECT
  USING (
    plan_id IN (
      SELECT p.id FROM public.team_onboarding_plans p
      WHERE p.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
        AND (
          p.team_member_id IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid())
          OR EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
        )
    )
  );

DROP POLICY IF EXISTS tos_update_self_or_admin ON public.team_onboarding_steps;
CREATE POLICY tos_update_self_or_admin ON public.team_onboarding_steps
  FOR UPDATE
  USING (
    plan_id IN (
      SELECT p.id FROM public.team_onboarding_plans p
      WHERE p.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
        AND (
          p.team_member_id IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid())
          OR EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
        )
    )
  )
  WITH CHECK (
    plan_id IN (
      SELECT p.id FROM public.team_onboarding_plans p
      WHERE p.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS tos_admin_insert_delete ON public.team_onboarding_steps;
CREATE POLICY tos_admin_insert_delete ON public.team_onboarding_steps
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
    AND plan_id IN (
      SELECT p.id FROM public.team_onboarding_plans p
      WHERE p.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
    AND plan_id IN (
      SELECT p.id FROM public.team_onboarding_plans p
      WHERE p.agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    )
  );

-- ============================================================================
-- compile_onboarding_plan(team_member_id, start_date) → plan_id
-- ============================================================================
CREATE OR REPLACE FUNCTION public.compile_onboarding_plan(
  p_team_member_id UUID,
  p_start_date     DATE DEFAULT NULL,
  p_target_end     DATE DEFAULT NULL,
  p_created_by     UUID DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency         UUID;
  v_role           TEXT;
  v_role_cat       TEXT;
  v_role_level     TEXT;
  v_start          DATE;
  v_target         DATE;
  v_plan_id        UUID;
  v_step_count     INT;
BEGIN
  -- Look up person
  SELECT agency_id, role, role_category, role_level
  INTO v_agency, v_role, v_role_cat, v_role_level
  FROM public.team
  WHERE id = p_team_member_id
    AND is_active = true
    AND archived_at IS NULL
    AND is_admin_backoffice = false;

  IF v_agency IS NULL THEN
    RAISE EXCEPTION 'Team member % not found, inactive, archived, or is admin/back-office (excluded from onboarding).', p_team_member_id;
  END IF;

  v_start  := COALESCE(p_start_date, CURRENT_DATE);
  v_target := COALESCE(p_target_end, v_start + INTERVAL '13 weeks');

  -- Create the plan (snapshot role)
  INSERT INTO public.team_onboarding_plans(
    agency_id, team_member_id,
    role_snapshot, role_category_snapshot, role_level_snapshot,
    start_date, target_end_date, status, created_by
  )
  VALUES (
    v_agency, p_team_member_id,
    v_role, v_role_cat, v_role_level,
    v_start, v_target, 'active', p_created_by
  )
  RETURNING id INTO v_plan_id;

  -- Copy applicable templates into steps (denormalized)
  INSERT INTO public.team_onboarding_steps(
    plan_id, template_key, title, description, phase, category,
    source_manual_id, source_anchor, sort_order, is_required
  )
  SELECT
    v_plan_id,
    t.template_key,
    t.title,
    t.description,
    t.phase,
    t.category,
    t.source_manual_id,
    t.source_anchor,
    t.sort_order,
    t.is_required
  FROM public.onboarding_step_templates t
  WHERE t.agency_id = v_agency
    AND t.is_active = true
    AND (
      t.applies_to_roles IS NULL OR array_length(t.applies_to_roles,1) IS NULL
      OR v_role = ANY(t.applies_to_roles)
    )
    AND (
      t.applies_to_role_categories IS NULL OR array_length(t.applies_to_role_categories,1) IS NULL
      OR v_role_cat = ANY(t.applies_to_role_categories)
    )
    AND (
      t.applies_to_role_levels IS NULL OR array_length(t.applies_to_role_levels,1) IS NULL
      OR v_role_level = ANY(t.applies_to_role_levels)
    );

  GET DIAGNOSTICS v_step_count = ROW_COUNT;

  IF v_step_count = 0 THEN
    RAISE NOTICE 'compile_onboarding_plan: 0 steps compiled for team_member % (role=%, cat=%, level=%). Seed templates before compiling.',
      p_team_member_id, v_role, v_role_cat, v_role_level;
  END IF;

  RETURN v_plan_id;
END $$;

GRANT EXECUTE ON FUNCTION public.compile_onboarding_plan(UUID, DATE, DATE, UUID) TO authenticated;;