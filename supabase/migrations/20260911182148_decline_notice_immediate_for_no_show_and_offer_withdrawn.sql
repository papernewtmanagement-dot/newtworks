-- =====================================================================
-- trg_candidate_decline_notice: no-show and offer-withdrawn letters send
-- immediately too
--
-- Peter 2026-09-11: "The no show and offer withdrawn letters can also be sent
-- out immediately." Both are decisions he makes deliberately on one person, so
-- there is nothing to gain by holding them for the Monday batch — and the offer
-- letter is the written confirmation of a phone call that already happened, so
-- a delay is worse than useless.
--
-- Send timing after this migration:
--   candidate_withdrew, no_show, offer_rescinded -> immediately, from this
--     trigger, the moment the row is set to declined.
--   everything else that sends (active_applicant, resume_score,
--     assessment_score) -> Monday 8am batch, recipe "Send Candidate Decline
--     Notices".
--   calibration_only, former_team, bounced_undeliverable -> never; the skip
--     lives in send_one_candidate_decline_notice, not here.
--
-- The batch still picks up anything this trigger could not send (no notice row
-- yet), so a failure here is a delay, never a lost letter.
--
-- Letter wording is untouched by this migration. It stays locked per
-- migration 20260911181458 and the function header block.
-- =====================================================================

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
  IF COALESCE(NEW.decline_reason, '') <> ALL (ARRAY[
       'candidate_withdrew', 'no_show', 'offer_rescinded'
     ]) THEN
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