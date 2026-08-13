-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 16:43:24 UTC (ledger name: dispatch_renewal_reminders_and_recipe) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701164324.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.dispatch_renewal_reminders(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, pg_catalog
AS $$
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
  v_url := v_url || '/functions/v1/renewal-reminder-runner';

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
    'target_function', 'renewal-reminder-runner',
    'output_summary',  format('Dispatched renewal-reminder-runner (request_id %s). See renewal_notification_log + alerts.', v_request_id),
    'records_processed', 0
  );
END;
$$;

-- Register the recipe. Cron: 12:00 UTC = 07:00 CT year-round (Central runs
-- UTC-5 in DST, UTC-6 in standard; 12 UTC = 7am CDT / 6am CST — either works
-- for a daily reminder). Runs after the existing 12:00 UTC Daily Briefing.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, composio_connection, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Daily Renewal Reminder Dispatcher',
  'Fires the renewal-reminder-runner edge function once per day. Updates alerts for all active team_renewals and sends emails on cadence hits (90/60/30/14/7/1/0 days out + daily past-due).',
  'cron',
  '5 12 * * *',
  'INTERNAL',
  NULL,
  'dispatch_renewal_reminders',
  '{"local_time": "07:05 CT / 06:05 CST", "cadence_days": [90, 60, 30, 14, 7, 1, 0]}'::jsonb,
  true
);
