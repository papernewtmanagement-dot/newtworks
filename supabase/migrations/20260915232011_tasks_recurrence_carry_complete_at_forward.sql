-- A repeating task that was booked at a time of day stays booked at that time of day.
-- The next occurrence gets the same clock time on its new date, so a weekly 9am task
-- keeps its 9am slot without anyone re-entering it.
-- Only the complete_at handling is new; the date maths, the guards and the rest of the
-- INSERT are unchanged from migration tasks_recurrence_spawn_next_on_close.
CREATE OR REPLACE FUNCTION public.tasks_spawn_next_occurrence()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  v_series        uuid;
  v_step          interval;
  v_next          date;
  v_next_at       timestamptz;
  v_next_complete timestamptz;
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

  -- Same clock time, new date. Calendar columns are deliberately left out of the INSERT
  -- so the new occurrence starts with no event and the hourly sync books a fresh one.
  v_next_complete := CASE
                       WHEN NEW.complete_at IS NULL THEN NULL
                       ELSE v_next + (NEW.complete_at AT TIME ZONE 'America/Chicago')::time
                     END AT TIME ZONE 'America/Chicago';

  INSERT INTO public.tasks (
    agency_id, title, description, assigned_to, created_by,
    due_date, due_at, remind_via_telegram, complete_at,
    priority, status, task_category, task_type, parent_task_id,
    importance, urgency, estimated_hours, priority_source, estimated_hours_source,
    in_weekly_focus, backlog_state,
    repeat_every, repeat_interval, repeat_series_id
  )
  VALUES (
    NEW.agency_id, NEW.title, NEW.description, NEW.assigned_to, 'recurrence',
    v_next, v_next_at, NEW.remind_via_telegram, v_next_complete,
    NEW.priority, 'open', NEW.task_category, NEW.task_type, NEW.parent_task_id,
    NEW.importance, NEW.urgency, NEW.estimated_hours, NEW.priority_source, NEW.estimated_hours_source,
    false, 'active',
    NEW.repeat_every, NEW.repeat_interval, v_series
  );

  RETURN NULL;
END $fn$;
