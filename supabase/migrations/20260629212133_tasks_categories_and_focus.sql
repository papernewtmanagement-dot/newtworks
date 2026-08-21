-- Lock task_category vocabulary to Peter's 6 values + index focus flag
ALTER TABLE public.tasks DROP CONSTRAINT IF EXISTS tasks_task_category_check;
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_task_category_check
  CHECK (task_category IS NULL OR task_category IN ('web_app','admin','marketing','training','handbook','playbook'));

CREATE INDEX IF NOT EXISTS idx_tasks_agency_in_weekly_focus
  ON public.tasks(agency_id, in_weekly_focus)
  WHERE in_weekly_focus = true;

CREATE INDEX IF NOT EXISTS idx_tasks_agency_task_category
  ON public.tasks(agency_id, task_category)
  WHERE task_category IS NOT NULL;
