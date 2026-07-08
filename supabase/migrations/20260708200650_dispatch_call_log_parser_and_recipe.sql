-- Migration: dispatch_call_log_parser_and_recipe
-- Applied: 2026-07-08
--
-- Dispatcher SQL fn + automation recipe for call-log-parser edge fn.
-- Fires hourly at :17 (offset from doc-processor which is at :07,:37).

CREATE OR REPLACE FUNCTION public.dispatch_call_log_parser(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url text;
  v_secret text;
  v_request_id bigint;
BEGIN
  SELECT setting_value INTO v_url FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/call-log-parser';

  SELECT setting_value INTO v_secret FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object(
             'agency_id', p_agency_id,
             'shared_secret', v_secret
           ),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 120000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'target_function', 'call-log-parser',
    'output_summary', format('Dispatched call-log-parser (request_id %s). See daily_call_activity for results.', v_request_id),
    'records_processed', 0
  );
END;
$function$;

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression,
  internal_handler, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'Call Log Parser (eGain daily intake)',
  'Parses eGain "Extension Activity.htm" attachments from statefarm.com Daily Call Log emails; upserts per-team-member daily metrics into daily_call_activity. Fires hourly to catch report as soon as it arrives; morning check-in reads yesterday''s block via render_daily_calls_block().',
  'cron',
  '17 * * * *',
  'dispatch_call_log_parser',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Call Log Parser (eGain daily intake)'
);
