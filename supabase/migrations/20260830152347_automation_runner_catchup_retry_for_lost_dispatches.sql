-- run_automation_recipe() dispatches via net.http_post, which is fire-and-forget.
-- If that POST is lost in flight, nothing is written to automation_run_log,
-- last_run_at is never updated, and the scheduled run is silently skipped
-- forever. Measured loss across all recipes: roughly 1-3% of scheduled fires.
--
-- This adds exactly ONE catch-up retry, 5 minutes after the missed occurrence,
-- and only when that occurrence produced no run-log row at all. A run that
-- fired and failed HAS a log row, so it is never retried here.
CREATE OR REPLACE FUNCTION public.run_due_automation_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now           TIMESTAMPTZ := date_trunc('minute', NOW());
  v_retry_at      TIMESTAMPTZ := date_trunc('minute', NOW()) - INTERVAL '5 minutes';
  v_recipe        RECORD;
  v_fired_count   INTEGER := 0;
  v_due           BOOLEAN;
  v_catchup       BOOLEAN;
BEGIN
  FOR v_recipe IN
    SELECT id, agency_id, recipe_name, cron_expression, timezone, last_run_at
    FROM public.automation_recipes
    WHERE is_active = TRUE
      AND trigger_type = 'cron'
      AND cron_expression IS NOT NULL
      AND length(trim(cron_expression)) > 0
      AND (last_run_at IS NULL OR date_trunc('minute', last_run_at) < v_now)
  LOOP
    v_due := public.cron_expression_matches(v_recipe.cron_expression, v_now, v_recipe.timezone);

    v_catchup := FALSE;
    IF NOT v_due THEN
      IF public.cron_expression_matches(v_recipe.cron_expression, v_retry_at, v_recipe.timezone) THEN
        SELECT NOT EXISTS (
          SELECT 1 FROM public.automation_run_log
          WHERE recipe_id = v_recipe.id
            AND run_at >= v_retry_at
        ) INTO v_catchup;
      END IF;
    END IF;

    IF v_due OR v_catchup THEN
      BEGIN
        PERFORM public.run_automation_recipe(
          v_recipe.id,
          CASE WHEN v_catchup THEN 'pg_cron_catchup' ELSE 'pg_cron' END
        );
        v_fired_count := v_fired_count + 1;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.automation_run_log (
          agency_id, recipe_id, status, error_message, output_summary, run_at
        ) VALUES (
          v_recipe.agency_id, v_recipe.id, 'failed', SQLERRM,
          'tick dispatch failed: ' || v_recipe.recipe_name, NOW()
        );
      END;
    END IF;
  END LOOP;

  RETURN v_fired_count;
END;
$function$;
