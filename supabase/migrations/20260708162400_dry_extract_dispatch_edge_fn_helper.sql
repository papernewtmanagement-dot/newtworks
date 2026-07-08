-- Tier-2 DRY (pair 1): extract shared _dispatch_edge_fn helper.
--
-- dispatch_license_reminders + dispatch_payroll_email_parser were near-identical:
-- both looked up supabase_url + shared_secret from settings, posted an agency-scoped
-- payload to an edge function via pg_net, returned a jsonb summary. Differences:
-- edge-fn name, timeout, and an optional trailing sentence in output_summary.
--
-- automation_recipes.internal_handler pins the callable name, so both public
-- wrappers stay. Wrappers become 3-line delegates.

CREATE OR REPLACE FUNCTION public._dispatch_edge_fn(
  p_agency_id      UUID,
  p_edge_fn_name   TEXT,
  p_timeout_ms     INT   DEFAULT 120000,
  p_summary_suffix TEXT  DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_url        TEXT;
  v_secret     TEXT;
  v_request_id BIGINT;
BEGIN
  SELECT setting_value INTO v_url FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/' || p_edge_fn_name;

  SELECT setting_value INTO v_secret FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url     := v_url,
    body    := jsonb_build_object('agency_id', p_agency_id, 'shared_secret', v_secret),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := p_timeout_ms
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id',        v_request_id,
    'target_function',   p_edge_fn_name,
    'output_summary',    format(
                           'Dispatched %s (request_id %s).%s',
                           p_edge_fn_name,
                           v_request_id,
                           CASE WHEN COALESCE(p_summary_suffix, '') = '' THEN '' ELSE ' ' || p_summary_suffix END
                         ),
    'records_processed', 0
  );
END $fn$;

COMMENT ON FUNCTION public._dispatch_edge_fn(UUID, TEXT, INT, TEXT) IS
  'Internal helper: post an agency-scoped payload to a Supabase edge function via pg_net.'
  ' Used by automation_recipes.internal_handler dispatchers. Returns jsonb suitable for'
  ' the automation_run_log.output column.';

CREATE OR REPLACE FUNCTION public.dispatch_license_reminders(p_agency_id UUID, p_recipe_id UUID)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN public._dispatch_edge_fn(
    p_agency_id, 'license-reminder-runner', 300000,
    'See license_notification_log + alerts.'
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.dispatch_payroll_email_parser(p_agency_id UUID, p_recipe_id UUID)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN public._dispatch_edge_fn(p_agency_id, 'payroll-email-parser', 120000);
END $fn$;
