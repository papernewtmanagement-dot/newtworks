-- The automation-runner now writes an automation_run_log row when the RECIPE
-- LOOKUP itself fails (database read error), so a database outage stops being
-- invisible. That row would otherwise switch off the automatic retry:
-- resweep_failed_automation_dispatches() treats "a run_log row exists since
-- the dispatch" as proof the recipe ran, and skips the retry.
--
-- This flag marks a row that was written BEFORE the recipe ever ran. The
-- resweep ignores flagged rows, so the transient case we most want retried
-- still gets retried.
ALTER TABLE public.automation_run_log
  ADD COLUMN IF NOT EXISTS is_pre_run_failure boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.automation_run_log.is_pre_run_failure IS
  'True when this row records a failure that happened BEFORE the recipe ran (recipe lookup failed). Such a row is not evidence the recipe executed, so resweep_failed_automation_dispatches() ignores it when deciding whether to retry a dispatch.';

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
        WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at
          AND l.is_pre_run_failure = FALSE)
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
      WHERE l.recipe_id = d.recipe_id AND l.run_at >= d.dispatched_at
        AND l.is_pre_run_failure = FALSE)
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