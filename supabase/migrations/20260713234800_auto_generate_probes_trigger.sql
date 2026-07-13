-- Auto-fire generate-custom-probes edge fn when a candidate moves to email_screen
-- status for the first time (idempotent: only fires when custom_probes IS NULL).
-- Fire-and-forget via pg_net; frontend regenerate button covers re-runs.

CREATE OR REPLACE FUNCTION public.auto_generate_probes_on_email_screen()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $$
DECLARE
  v_service_key text;
  v_url text := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/generate-custom-probes';
BEGIN
  IF NEW.status = 'email_screen'
     AND (OLD.status IS DISTINCT FROM NEW.status)
     AND NEW.custom_probes IS NULL THEN

    SELECT setting_value INTO v_service_key
    FROM public.settings
    WHERE agency_id = NEW.agency_id
      AND setting_key = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_key IS NULL THEN
      RAISE WARNING 'auto_generate_probes: settings.supabase_service_role_key missing for agency %', NEW.agency_id;
      RETURN NEW;
    END IF;

    PERFORM net.http_post(
      url := v_url,
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||v_service_key
      ),
      body := jsonb_build_object('assessment_id', NEW.id),
      timeout_milliseconds := 90000
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_generate_probes_on_email_screen ON public.team_assessments;

CREATE TRIGGER trg_auto_generate_probes_on_email_screen
  AFTER UPDATE OF status ON public.team_assessments
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_generate_probes_on_email_screen();

COMMENT ON FUNCTION public.auto_generate_probes_on_email_screen() IS
  'AFTER UPDATE trigger on team_assessments \u2014 fires generate-custom-probes edge fn when a candidate moves to email_screen and has no custom_probes yet. Uses pg_net fire-and-forget. Manual regenerate button in CandidateDetail.jsx covers re-runs.';
