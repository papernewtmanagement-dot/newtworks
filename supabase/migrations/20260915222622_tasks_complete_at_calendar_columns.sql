-- "Complete at" time on a task, and the calendar event it produces.
-- complete_at                 = when Peter intends to actually do the task
-- calendar_event_id           = the Google event id, so the event is edited in place, never recreated
-- calendar_pg_net_request_id  = the async request id, read back to capture the event id
-- calendar_pushed_complete_at = the complete_at currently sitting on the calendar; when it differs
--                               from complete_at the event needs patching
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS complete_at                 timestamptz;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS calendar_event_id           text;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS calendar_pg_net_request_id  bigint;
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS calendar_pushed_complete_at timestamptz;

-- Tasks that still owe the calendar something.
CREATE INDEX IF NOT EXISTS tasks_calendar_pending_idx
  ON public.tasks (agency_id)
  WHERE complete_at IS NOT NULL OR calendar_event_id IS NOT NULL;

-- Where the task events go. Left empty on purpose: the calendar does not exist yet,
-- and tasks_calendar_dispatch does nothing at all while this is blank.
INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_by)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'gcal_tasks_calendar_id', '', 'text',
       'Google Calendar id for the Story Agency Tasks calendar. Blank = no calendar yet, task events are not sent.',
       'newtworks'
WHERE NOT EXISTS (
  SELECT 1 FROM public.settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND setting_key = 'gcal_tasks_calendar_id'
);
