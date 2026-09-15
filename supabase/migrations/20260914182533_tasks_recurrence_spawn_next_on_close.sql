ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS repeat_every text,
  ADD COLUMN IF NOT EXISTS repeat_interval smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS repeat_series_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tasks_repeat_every_check') THEN
    ALTER TABLE public.tasks
      ADD CONSTRAINT tasks_repeat_every_check
      CHECK (repeat_every IS NULL OR repeat_every IN ('day','week','month','year'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tasks_repeat_interval_check') THEN
    ALTER TABLE public.tasks
      ADD CONSTRAINT tasks_repeat_interval_check
      CHECK (repeat_interval >= 1);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS tasks_repeat_series_open_idx
  ON public.tasks (repeat_series_id) WHERE status = 'open' AND repeat_series_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.tasks_spawn_next_occurrence()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_series   uuid;
  v_step     interval;
  v_next     date;
  v_next_at  timestamptz;
BEGIN
  IF NEW.repeat_every IS NULL THEN
    RETURN NULL;
  END IF;

  v_series := COALESCE(NEW.repeat_series_id, NEW.id);

  -- stamp the series id on the row that just closed, without re-firing this trigger
  IF NEW.repeat_series_id IS NULL THEN
    UPDATE public.tasks SET repeat_series_id = v_series WHERE id = NEW.id;
  END IF;

  -- one open instance per series at a time
  IF EXISTS (
    SELECT 1 FROM public.tasks
    WHERE repeat_series_id = v_series AND status = 'open'
  ) THEN
    RETURN NULL;
  END IF;

  v_step := (NEW.repeat_interval::text || ' ' ||
             CASE NEW.repeat_every
               WHEN 'day'   THEN 'days'
               WHEN 'week'  THEN 'weeks'
               WHEN 'month' THEN 'months'
               WHEN 'year'  THEN 'years'
             END)::interval;

  -- next date comes off the schedule, not off the close date; skip any occurrence already past
  v_next := COALESCE(NEW.due_date, CURRENT_DATE) + v_step;
  WHILE v_next <= CURRENT_DATE LOOP
    v_next := v_next + v_step;
  END LOOP;

  v_next_at := CASE
                 WHEN NEW.due_at IS NULL THEN NULL
                 ELSE v_next + (NEW.due_at AT TIME ZONE 'America/Chicago')::time
               END AT TIME ZONE 'America/Chicago';

  INSERT INTO public.tasks (
    agency_id, title, description, assigned_to, created_by,
    due_date, due_at, remind_via_telegram,
    priority, status, task_category, task_type, parent_task_id,
    importance, urgency, estimated_hours, priority_source, estimated_hours_source,
    in_weekly_focus, backlog_state,
    repeat_every, repeat_interval, repeat_series_id
  )
  VALUES (
    NEW.agency_id, NEW.title, NEW.description, NEW.assigned_to, 'recurrence',
    v_next, v_next_at, NEW.remind_via_telegram,
    NEW.priority, 'open', NEW.task_category, NEW.task_type, NEW.parent_task_id,
    NEW.importance, NEW.urgency, NEW.estimated_hours, NEW.priority_source, NEW.estimated_hours_source,
    false, 'active',
    NEW.repeat_every, NEW.repeat_interval, v_series
  );

  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS zz_tasks_spawn_next_occurrence ON public.tasks;
CREATE TRIGGER zz_tasks_spawn_next_occurrence
AFTER UPDATE OF status ON public.tasks
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM 'closed' AND NEW.status = 'closed')
EXECUTE FUNCTION public.tasks_spawn_next_occurrence();
