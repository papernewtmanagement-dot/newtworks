-- Deleting a task removes its calendar event too. Without this the row disappears and
-- tasks_calendar_dispatch never sees it again, leaving a booking on the calendar with
-- nothing behind it.
CREATE OR REPLACE FUNCTION public.tasks_calendar_cleanup_on_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','net'
AS $fn$
DECLARE v_cal text;
BEGIN
  IF OLD.calendar_event_id IS NULL THEN
    RETURN OLD;
  END IF;

  SELECT NULLIF(btrim(setting_value), '') INTO v_cal
  FROM public.settings
  WHERE agency_id = OLD.agency_id AND setting_key = 'gcal_tasks_calendar_id';

  IF v_cal IS NULL THEN
    RETURN OLD;
  END IF;

  -- Never let a calendar hiccup block the delete the user asked for.
  BEGIN
    PERFORM public.composio_post(
      public.calendar_event_delete_request(OLD.agency_id, v_cal, OLD.calendar_event_id, 'all'));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'tasks_calendar_cleanup_on_delete: could not remove event % (%)', OLD.calendar_event_id, SQLERRM;
  END;

  RETURN OLD;
END $fn$;

DROP TRIGGER IF EXISTS zz_tasks_calendar_cleanup_on_delete ON public.tasks;
CREATE TRIGGER zz_tasks_calendar_cleanup_on_delete
BEFORE DELETE ON public.tasks
FOR EACH ROW
EXECUTE FUNCTION public.tasks_calendar_cleanup_on_delete();
