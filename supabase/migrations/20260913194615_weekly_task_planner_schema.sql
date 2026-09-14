-- Weekly task planner: scoring columns, override locks, rules table.
-- Additive only. Nothing existing is dropped or rewritten.

ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS importance smallint;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS urgency smallint;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS estimated_hours numeric(5,2);
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS priority_source text NOT NULL DEFAULT 'auto';
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS estimated_hours_source text NOT NULL DEFAULT 'auto';
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS scored_at timestamptz;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS week_of date;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS weeks_carried smallint NOT NULL DEFAULT 0;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS backlog_state text NOT NULL DEFAULT 'active';

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_importance_check
    CHECK (importance IS NULL OR (importance >= 0 AND importance <= 100));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_urgency_check
    CHECK (urgency IS NULL OR (urgency >= 0 AND urgency <= 100));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_priority_check
    CHECK (priority IS NULL OR priority = ANY (ARRAY['low','medium','high','critical']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_priority_source_check
    CHECK (priority_source = ANY (ARRAY['auto','manual']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_hours_source_check
    CHECK (estimated_hours_source = ANY (ARRAY['auto','manual']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.tasks ADD CONSTRAINT tasks_backlog_state_check
    CHECK (backlog_state = ANY (ARRAY['active','someday']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_tasks_week_of ON public.tasks (week_of) WHERE week_of IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_backlog_state ON public.tasks (backlog_state);

COMMENT ON COLUMN public.tasks.priority_source IS
  'auto = set by the Sunday scoring run. manual = Peter or Marie edited it in the app; the run must never overwrite it.';
COMMENT ON COLUMN public.tasks.estimated_hours_source IS
  'auto = set by the Sunday scoring run. manual = edited in the app; the run must never overwrite it.';
COMMENT ON COLUMN public.tasks.importance IS
  'How much this matters, 0-100. Scored separately from urgency on purpose. Zhu, Yang & Hsee 2018 (mere urgency effect): people pick urgent-but-trivial over important-but-later when the two are blended into one number.';
COMMENT ON COLUMN public.tasks.urgency IS
  'How soon this needs doing, 0-100. Driven by due date and rollover count, not by age. An old task with no due date is not urgent.';

-- Tunable weights and pattern rules. Peter edits these instead of editing code.
CREATE TABLE IF NOT EXISTS public.task_scoring_rules (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  rule_kind text NOT NULL,
  match_category text,
  match_pattern text,
  importance_value smallint,
  importance_bump smallint DEFAULT 0,
  urgency_bump smallint DEFAULT 0,
  hours_value numeric(5,2),
  notes text,
  priority smallint NOT NULL DEFAULT 50,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT task_scoring_rules_kind_check
    CHECK (rule_kind = ANY (ARRAY['category_weight','keyword','type_hours','setting']))
);

CREATE INDEX IF NOT EXISTS idx_task_scoring_rules_lookup
  ON public.task_scoring_rules (agency_id, rule_kind, is_active);

ALTER TABLE public.task_scoring_rules ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY task_scoring_rules_owner_full ON public.task_scoring_rules
    FOR ALL USING (
      agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND EXISTS (SELECT 1 FROM public.users u
                  WHERE u.auth_user_id = auth.uid() AND u.role = 'owner')
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY task_scoring_rules_manager_read ON public.task_scoring_rules
    FOR SELECT USING (
      agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND EXISTS (SELECT 1 FROM public.users u
                  WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager'))
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON TABLE public.task_scoring_rules IS
  'Tunable inputs for the Sunday task scoring run. category_weight sets base importance per category. keyword bumps importance/urgency on a title or description match. type_hours sets the default hour estimate per task_type. setting holds single values (weekly hour budget, item cap, planning-fallacy multiplier).';