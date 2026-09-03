-- Peter directive 2026-09-02: decline letters go out in one weekly batch on
-- Monday morning, NOT the moment a candidate is set to declined.
--
-- Why: an immediate send ties the letter to the interview that just happened,
-- and most declines are automatic resume declines that fired ~30 minutes after
-- the person applied. Both read as a machine. One weekly send decouples the
-- letter from the moment.
--
-- Withdrawals stay immediate. That letter is a reply to someone who wrote in
-- to say they are stepping out; holding it a week defeats its purpose.

CREATE OR REPLACE FUNCTION public.trg_candidate_decline_notice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Only withdrawals send on the spot. Everything else waits for the Monday
  -- batch (recipe "Send Candidate Decline Notices", cron 0 8 * * 1 CT), which
  -- picks up any declined candidate with no notice row yet.
  IF COALESCE(NEW.decline_reason, '') IS DISTINCT FROM 'candidate_withdrew' THEN
    RETURN NULL;
  END IF;

  -- Never let a send problem block the decline itself from saving.
  BEGIN
    PERFORM public.send_one_candidate_decline_notice(NEW.agency_id, NEW.id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                               module_reference, related_id, is_read, is_resolved)
    VALUES (NEW.agency_id, 'decline_notice_send_failed', 'warning',
            'Withdrawal notice could not be sent',
            'The decline saved, but the withdrawal reply failed: ' || SQLERRM ||
            ' The Monday batch will retry.',
            'hiring', NEW.id, false, false);
  END;
  RETURN NULL;
END;
$function$;

-- Recipe cadence change applied alongside this migration:
-- UPDATE automation_recipes SET cron_expression = '0 8 * * 1'
--   WHERE recipe_name = 'Send Candidate Decline Notices';  (was '0 8 * * *')
