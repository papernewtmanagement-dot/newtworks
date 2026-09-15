CREATE OR REPLACE FUNCTION public.trg_candidate_decline_notice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- The three reasons Peter picks deliberately, one person at a time, send on
  -- the spot. Everything else waits for the Monday batch (recipe "Send
  -- Candidate Decline Notices", cron 0 8 * * 1 CT), which picks up any declined
  -- candidate with no notice row yet.
  --
  -- Peter 2026-09-14 adds a fourth case that has nothing to do with the reason:
  -- anyone holding an interview that has not happened yet. Their booking is
  -- being taken off the calendar this same second, and he is not going to show
  -- up for it, so they cannot be left waiting up to a week to find out why the
  -- meeting vanished. Christina Bennett was declined 17 minutes before hers.
  IF COALESCE(NEW.decline_reason, '') <> ALL (ARRAY[
       'candidate_withdrew', 'no_show', 'offer_rescinded'
     ])
     AND NOT (
       NEW.interview_scheduled_start IS NOT NULL
       AND NEW.interview_scheduled_start > now()
       AND (NEW.interview_booked_at IS NOT NULL OR NEW.interview_calendar_event_id IS NOT NULL)
     ) THEN
    RETURN NULL;
  END IF;

  -- Never let a send problem block the decline itself from saving.
  BEGIN
    PERFORM public.send_one_candidate_decline_notice(NEW.agency_id, NEW.id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                               module_reference, related_id, is_read, is_resolved)
    VALUES (NEW.agency_id, 'decline_notice_send_failed', 'warning',
            'Decline letter could not be sent',
            'The decline saved, but the letter failed: ' || SQLERRM ||
            ' The Monday batch will retry.',
            'hiring', NEW.id, false, false);
  END;
  RETURN NULL;
END;
$function$;
