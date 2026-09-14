-- Record the dispatch inside run_automation_recipe itself rather than in each runner.
-- Every path that queues a recipe goes through here — the hourly tick, the team
-- check-in tick, the queue-drainer trigger, manual runs — so one change covers all of
-- them and they cannot drift apart.
CREATE OR REPLACE FUNCTION public.run_automation_recipe(p_recipe_id uuid, p_triggered_by text DEFAULT 'manual'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_recipe        RECORD;
  v_supabase_url  TEXT;
  v_runner_secret TEXT;
  v_request_id    BIGINT;
BEGIN
  SELECT * INTO v_recipe FROM public.automation_recipes WHERE id = p_recipe_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recipe % not found', p_recipe_id;
  END IF;

  IF v_recipe.agency_id IS NULL THEN
    RAISE EXCEPTION 'Recipe % has no agency_id set.', p_recipe_id;
  END IF;

  v_supabase_url := public.get_setting(v_recipe.agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', v_recipe.agency_id;
  END IF;

  v_runner_secret := public.get_setting(v_recipe.agency_id, 'automation_runner_cron_secret');
  IF v_runner_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', v_recipe.agency_id;
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/automation-runner',
    headers := public.edge_fn_headers(),
    body := jsonb_build_object(
      'shared_secret', v_runner_secret,
      'recipe_id',     p_recipe_id::text,
      'triggered_by',  p_triggered_by
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  -- The post is fire-and-forget, so this row is the only record that the attempt
  -- happened. resweep_failed_automation_dispatches reads it back against the pg_net
  -- response and re-queues anything the edge function never answered.
  IF p_triggered_by <> 'pg_cron_resweep' THEN
    INSERT INTO public.automation_dispatch_log (recipe_id, request_id)
    VALUES (p_recipe_id, v_request_id);
  END IF;

  RETURN v_request_id;
END;
$function$;

-- Hang the resweep off the existing runner tick. No new pg_cron job.
SELECT cron.alter_job(
  1,
  command := $cmd$
    SELECT public.run_due_automation_recipes();
    SELECT public.resweep_failed_automation_dispatches();
    SELECT public.team_checkin_sweep_stale_eod_summaries();
  $cmd$);
