-- Add task_category (Peter's 6 working categories) + in_weekly_focus boolean.
-- module_reference column stays intact (data_label_preservation) — this is additive only.

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS task_category TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'tasks_task_category_check'
      AND conrelid = 'public.tasks'::regclass
  ) THEN
    ALTER TABLE public.tasks
      ADD CONSTRAINT tasks_task_category_check
      CHECK (task_category IS NULL OR task_category IN (
        'web_app','admin','marketing','training','handbook','playbook'
      ));
  END IF;
END $$;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS in_weekly_focus BOOLEAN NOT NULL DEFAULT false;

-- Partial index for the "This Week" tab — only active focused tasks.
CREATE INDEX IF NOT EXISTS idx_tasks_weekly_focus_active
  ON public.tasks (agency_id, in_weekly_focus)
  WHERE in_weekly_focus = true AND status <> 'closed';

CREATE INDEX IF NOT EXISTS idx_tasks_task_category
  ON public.tasks (agency_id, task_category)
  WHERE task_category IS NOT NULL;
