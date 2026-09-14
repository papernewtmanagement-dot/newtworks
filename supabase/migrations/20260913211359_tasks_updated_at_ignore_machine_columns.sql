-- updated_at must mean "a person touched this", not "a machine scored this".
-- Otherwise every Sunday run resets the staleness clock and nothing ever ages out.
CREATE OR REPLACE FUNCTION public.tasks_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF ( NEW.title, NEW.description, NEW.assigned_to, NEW.due_date, NEW.due_at,
       NEW.priority, NEW.status, NEW.task_category, NEW.task_type, NEW.parent_task_id,
       NEW.related_id, NEW.completed_at, NEW.priority_source, NEW.estimated_hours_source,
       NEW.remind_via_telegram )
     IS NOT DISTINCT FROM
     ( OLD.title, OLD.description, OLD.assigned_to, OLD.due_date, OLD.due_at,
       OLD.priority, OLD.status, OLD.task_category, OLD.task_type, OLD.parent_task_id,
       OLD.related_id, OLD.completed_at, OLD.priority_source, OLD.estimated_hours_source,
       OLD.remind_via_telegram )
  THEN
    NEW.updated_at := OLD.updated_at;   -- planner-only write, clock stays put
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_tasks_updated ON public.tasks;
CREATE TRIGGER trg_tasks_updated BEFORE UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.tasks_set_updated_at();

COMMENT ON FUNCTION public.tasks_set_updated_at IS
  'Keeps tasks.updated_at frozen when only planner columns change (importance, urgency, estimated_hours, scored_at, week_of, in_weekly_focus, scheduled_day, weeks_carried, backlog_state, parked fields). Staleness rules read updated_at, so a machine write must not look like human activity.';

-- Repair the damage from the first scoring run, using the snapshot taken beforehand.
ALTER TABLE public.tasks DISABLE TRIGGER trg_tasks_updated;
UPDATE public.tasks t SET updated_at = s.updated_at
  FROM public.tasks_priority_snapshot_20260913 s
 WHERE t.id = s.id AND t.updated_at <> s.updated_at;
ALTER TABLE public.tasks ENABLE TRIGGER trg_tasks_updated;