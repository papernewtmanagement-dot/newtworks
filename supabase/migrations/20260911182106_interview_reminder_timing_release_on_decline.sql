-- Peter directive 2026-09-11 (second pass):
--   * reminders go out three days before and the day before (Steiner et al.
--     2018, Am J Manag Care 24:377: reminders at 3 days and 1 day beat either
--     alone), not two days in a row;
--   * declining a candidate who has an interview booked frees the slot
--     automatically (calendar event canceled quietly, booking cleared);
--   * when an earlier slot opens, candidates booked further out are offered
--     it (stamp below throttles the offer emails to one per 3 days).

ALTER TABLE public.hiring_candidates RENAME COLUMN interview_reminder_2d_sent_at TO interview_reminder_3d_sent_at;
ALTER TABLE public.hiring_candidates RENAME COLUMN interview_reminder_day_sent_at TO interview_reminder_1d_sent_at;
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS interview_unconfirmed_alerted_at timestamptz,
  ADD COLUMN IF NOT EXISTS interview_earlier_offer_sent_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.interview_reminder_3d_sent_at IS 'Confirm-or-reschedule reminder sent (three days before; next morning run when booked with less notice).';
COMMENT ON COLUMN public.hiring_candidates.interview_reminder_1d_sent_at IS 'Day-before reminder sent.';
COMMENT ON COLUMN public.hiring_candidates.interview_unconfirmed_alerted_at IS 'Owner was DMed on the morning of an unconfirmed interview.';
COMMENT ON COLUMN public.hiring_candidates.interview_earlier_offer_sent_at IS 'Last "an earlier time opened up" email; one per 3 days at most.';

UPDATE public.automation_recipes
   SET recipe_description = 'Daily at 7:59 Central. Emails every booked candidate a confirm-or-reschedule ask three days before the interview and a reminder the day before, both with Yes / Reschedule / No-longer-interested links. Morning of, still unconfirmed -> Telegram DM to the owner. Same run offers earlier open times to candidates booked further out.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Interview Reminders';

-- Decline in the pipeline -> the booked interview is released. Fires only on
-- the transition into declined, only when a booking exists, and never blocks
-- the decline itself: the edge call is wrapped so a dispatch failure raises
-- a warning, not an error. The withdraw path clears the booking in the same
-- UPDATE that sets declined, so it does not double-fire.
CREATE OR REPLACE FUNCTION public.trg_release_interview_on_decline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  IF NEW.status = 'declined' AND OLD.status IS DISTINCT FROM 'declined'
     AND (NEW.interview_booked_at IS NOT NULL OR NEW.interview_calendar_event_id IS NOT NULL) THEN
    BEGIN
      SELECT setting_value INTO v_url FROM public.settings WHERE agency_id = NEW.agency_id AND setting_key = 'supabase_url';
      SELECT setting_value INTO v_secret FROM public.settings WHERE agency_id = NEW.agency_id AND setting_key = 'automation_runner_cron_secret';
      IF v_url IS NULL OR v_secret IS NULL THEN
        RAISE WARNING 'trg_release_interview_on_decline: settings missing for agency %', NEW.agency_id;
        RETURN NEW;
      END IF;
      PERFORM net.http_post(
        url     := v_url || '/functions/v1/hiring-interview-scheduler',
        body    := jsonb_build_object('agency_id', NEW.agency_id, 'shared_secret', v_secret, 'mode', 'release_booking', 'candidate_id', NEW.id),
        headers := public.edge_fn_headers(),
        timeout_milliseconds := 60000
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'trg_release_interview_on_decline: dispatch failed for candidate % (%)', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_release_interview_on_decline ON public.hiring_candidates;
CREATE TRIGGER trg_release_interview_on_decline
  AFTER UPDATE OF status ON public.hiring_candidates
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_release_interview_on_decline();
