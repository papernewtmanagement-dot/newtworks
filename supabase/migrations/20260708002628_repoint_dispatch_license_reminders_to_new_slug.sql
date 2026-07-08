-- 20260708002628_repoint_dispatch_license_reminders_to_new_slug
-- Repoints dispatch_license_reminders() to hit /functions/v1/license-reminder-runner.
-- Companion to Supabase edge function slug rename renewal-reminder-runner -> license-reminder-runner.

CREATE OR REPLACE FUNCTION public.dispatch_license_reminders(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url        text;
  v_secret     text;
  v_request_id bigint;
BEGIN
  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/license-reminder-runner';

  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'agency_id',     p_agency_id,
                 'shared_secret', v_secret
               ),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 300000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id',      v_request_id,
    'target_function', 'license-reminder-runner',
    'output_summary',  format('Dispatched license-reminder-runner (request_id %s). See license_notification_log + alerts.', v_request_id),
    'records_processed', 0
  );
END;
$function$;
