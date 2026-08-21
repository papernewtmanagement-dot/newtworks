CREATE OR REPLACE FUNCTION public.dispatch_wrapup_checker(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_supabase_url text;
  v_secret text;
  v_request_id bigint;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF v_local_time IS NOT NULL AND NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;
  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/wrapup-checker',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id', p_agency_id::text,
      'recipe_id', p_recipe_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 120000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched wrapup-checker (request_id ' || v_request_id || '). Awaiting response...',
    'request_id', v_request_id,
    'target_function', 'wrapup-checker'
  );
END;
$function$;

-- Schedule: Sunday 9 AM CT (dow=0, DST self-correcting via local_time gate)
-- 09:00 CDT = 14:00 UTC, 09:00 CST = 15:00 UTC
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, composio_action, internal_handler,
  cron_expression, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Email Check',
  'Sunday 9:00 AM CT: scans Gmail for wrapup emails received at paper.newt.management@gmail.com during the just-closed Sun-Sat week. Writes per-person status to team_weekly_wrapups and posts a tally to the team Telegram group. DST self-correcting via local_time gate.',
  'cron',
  'INTERNAL',
  'dispatch_wrapup_checker',
  '0 14,15 * * 0',
  jsonb_build_object('local_time', '09:00'),
  true
);
