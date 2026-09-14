CREATE OR REPLACE FUNCTION public.trg_release_interview_on_decline()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Frees an interview booking when a candidate is declined.
-- Peter 2026-09-14: a decline must NEVER touch an interview that has already
-- happened or has already begun. Only a booking whose start time is still in
-- the future gets released (slot freed, calendar event removed).
-- interview_scheduled_start is always populated on a booked candidate, so a
-- NULL start means a held slot with no time yet -- that still releases.
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  IF NEW.status = 'declined' AND OLD.status IS DISTINCT FROM 'declined'
     AND (NEW.interview_booked_at IS NOT NULL OR NEW.interview_calendar_event_id IS NOT NULL)
     AND (NEW.interview_scheduled_start IS NULL OR NEW.interview_scheduled_start > now()) THEN
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
END $function$;
