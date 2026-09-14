-- Decision 3, root cause. run_automation_recipe does not run the handler. It queues an
-- async HTTP post to the automation-runner edge function and returns straight away,
-- which is why the tick finishes in 0.3 seconds. When that call fails, the edge
-- function reports "Recipe <id> not found: Gateway Timeout" and nothing is written:
-- no run-log row, no last_run_at bump. The drop is completely silent.
--
-- Five drops in the last six hours. Most recipes recover by accident, because the
-- runner's two-hour look-back re-offers the slot on the next tick. A once-a-week
-- recipe does not: two consecutive drops push the slot out of the window and the run
-- is gone for the week. That is what happened to the three Saturday close recipes on
-- 2026-09-12, and why "Quarter Close — raise review" has not run since 2026-09-05.
--
-- Fix: record every dispatch against its pg_net request id, then read the response
-- back on the next tick and re-dispatch anything that failed.

CREATE TABLE IF NOT EXISTS public.automation_dispatch_log (
  id            bigserial PRIMARY KEY,
  recipe_id     uuid NOT NULL REFERENCES public.automation_recipes(id) ON DELETE CASCADE,
  request_id    bigint,
  slot          timestamptz,
  dispatched_at timestamptz NOT NULL DEFAULT now(),
  retry_count   smallint NOT NULL DEFAULT 0,
  resolved_at   timestamptz
);

CREATE INDEX IF NOT EXISTS automation_dispatch_log_open_idx
  ON public.automation_dispatch_log (dispatched_at)
  WHERE resolved_at IS NULL;

ALTER TABLE public.automation_dispatch_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS automation_dispatch_log_service ON public.automation_dispatch_log;
CREATE POLICY automation_dispatch_log_service ON public.automation_dispatch_log
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Re-dispatch anything whose pg_net response came back failed, timed out, or missing
-- a status, and that has produced no run-log row since it was dispatched. Two attempts
-- maximum, then it is left alone and shows up as an alert. Rides the existing hourly
-- tick; no new pg_cron job.
CREATE OR REPLACE FUNCTION public.resweep_failed_automation_dispatches()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
DECLARE
  v_row     RECORD;
  v_retried INTEGER := 0;
  v_new_req BIGINT;
BEGIN
  FOR v_row IN
    SELECT d.id, d.recipe_id, d.retry_count, r.recipe_name, r.agency_id
    FROM public.automation_dispatch_log d
    JOIN public.automation_recipes r ON r.id = d.recipe_id
    JOIN net._http_response resp ON resp.id = d.request_id
    WHERE d.resolved_at IS NULL
      AND d.retry_count < 2
      AND d.dispatched_at > now() - INTERVAL '3 hours'
      AND d.dispatched_at < now() - INTERVAL '2 minutes'
      AND r.is_active = TRUE
      AND (resp.status_code IS NULL OR resp.status_code >= 400 OR resp.timed_out)
      AND NOT EXISTS (
        SELECT 1 FROM public.automation_run_log l
        WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at)
    ORDER BY d.dispatched_at
  LOOP
    BEGIN
      v_new_req := public.run_automation_recipe(v_row.recipe_id, 'pg_cron_resweep');
      UPDATE public.automation_dispatch_log
      SET retry_count = v_row.retry_count + 1, resolved_at = now()
      WHERE id = v_row.id;
      INSERT INTO public.automation_dispatch_log (recipe_id, request_id, retry_count)
      VALUES (v_row.recipe_id, v_new_req, v_row.retry_count + 1);
      v_retried := v_retried + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.automation_dispatch_log SET resolved_at = now() WHERE id = v_row.id;
    END;
  END LOOP;

  -- A dispatch that burned both attempts is a real failure, not a blip. Surface it.
  INSERT INTO public.alerts (agency_id, module_reference, severity, title, message, is_resolved, created_at)
  SELECT r.agency_id, 'automations', 'high',
         'Automation dispatch failed twice: ' || r.recipe_name,
         format('The runner queued %s twice and the edge function did not answer either time. It has not run since %s Central.',
                r.recipe_name,
                to_char(COALESCE(r.last_run_at, r.created_at) AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD HH24:MI')),
         FALSE, now()
  FROM public.automation_dispatch_log d
  JOIN public.automation_recipes r ON r.id = d.recipe_id
  WHERE d.retry_count >= 2
    AND d.resolved_at IS NULL
    AND d.dispatched_at > now() - INTERVAL '3 hours'
    AND NOT EXISTS (
      SELECT 1 FROM public.automation_run_log l
      WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at)
    AND NOT EXISTS (
      SELECT 1 FROM public.alerts a
      WHERE a.module_reference = 'automations'
        AND a.title = 'Automation dispatch failed twice: ' || r.recipe_name
        AND a.is_resolved = FALSE);

  UPDATE public.automation_dispatch_log SET resolved_at = now()
  WHERE resolved_at IS NULL AND dispatched_at < now() - INTERVAL '3 hours';

  DELETE FROM public.automation_dispatch_log WHERE dispatched_at < now() - INTERVAL '7 days';

  RETURN v_retried;
END;
$function$;
