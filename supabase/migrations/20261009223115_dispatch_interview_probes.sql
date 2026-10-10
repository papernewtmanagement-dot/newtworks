-- Interview questions build themselves when an interview is booked (Peter
-- 2026-10-09). Reuses generate-custom-probes, the same builder behind the
-- candidate page's "Generate custom probes" button. Never overwrites questions
-- already on the candidate (built earlier, by button or by interview plan).
-- A booking that failed to build questions retries on the next time change.
CREATE OR REPLACE FUNCTION public.dispatch_interview_probes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url text;
BEGIN
  IF NEW.is_test_candidate IS TRUE THEN RETURN NULL; END IF;
  IF NEW.decision_at IS NOT NULL THEN RETURN NULL; END IF;
  IF NEW.custom_probes IS NOT NULL THEN RETURN NULL; END IF;

  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN RETURN NULL; END IF;

  PERFORM net.http_post(
    url     := v_url || '/functions/v1/generate-custom-probes',
    headers := public.edge_fn_headers(),
    body    := jsonb_build_object('assessment_id', NEW.id),
    timeout_milliseconds := 120000
  );
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_dispatch_interview_probes ON public.hiring_candidates;
CREATE TRIGGER trg_dispatch_interview_probes
  AFTER INSERT OR UPDATE OF interview_scheduled_start ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.interview_scheduled_start IS NOT NULL AND NEW.custom_probes IS NULL)
  EXECUTE FUNCTION public.dispatch_interview_probes();

