
-- ============================================================================
-- Migration: Fix silent automation failures + auto-create alerts
-- ============================================================================
-- ROOT CAUSE: dispatch_email_archiver and dispatch_document_processor used
-- pg_net's net.http_post in fire-and-forget mode. They returned "dispatched
-- (request_id N)" immediately, before the downstream Edge Function actually
-- responded. When the Edge Function returned HTTP 500 (e.g. expired Gmail
-- credential), the dispatch wrapper had already reported success to
-- run_internal_recipe -> automation_run_log. Result: 30+ days of HTTP 500
-- failures logged as "success" in the dashboard.
--
-- FIX:
--   1. New helper public._dispatch_and_wait() — fires the POST, polls
--      net._http_response for up to 90 seconds, RAISEs on HTTP >=400 or on
--      no-response timeout, surfaces real records_processed/output_summary
--      on success.
--   2. dispatch_email_archiver and dispatch_document_processor rewritten to
--      use the helper. RAISEs now propagate through run_internal_recipe to
--      the automation-runner TS try/catch, which logs status='failed' with
--      the real error message.
--   3. Alert trigger trg_alert_on_recipe_run on automation_run_log:
--        - status='failed'  → upsert one open alert per (recipe_id) in
--          public.alerts (alert_type='automation_failure', severity='warning',
--          module_reference='automations'). If an open alert already exists
--          for the recipe, its message is updated; we don't spam new rows.
--        - status='success' → auto-resolves any open automation_failure
--          alerts for that recipe.
-- ============================================================================

-- 1) HELPER: synchronous HTTP POST that waits for the response
CREATE OR REPLACE FUNCTION public._dispatch_and_wait(
  p_agency_id        uuid,
  p_url              text,
  p_body             jsonb,
  p_handler_name     text,
  p_max_wait_seconds int DEFAULT 90
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_request_id     bigint;
  v_status_code    int;
  v_body_text      text;
  v_err            text;
  v_timed_out      boolean;
  v_attempts       int := 0;
  v_response_json  jsonb;
BEGIN
  -- Fire the HTTP POST
  SELECT net.http_post(
    url := p_url,
    headers := jsonb_build_object('Content-Type','application/json'),
    body := p_body,
    timeout_milliseconds := p_max_wait_seconds * 1000
  ) INTO v_request_id;

  -- Poll net._http_response until status arrives, error arrives, or we time out
  WHILE v_attempts < p_max_wait_seconds LOOP
    SELECT status_code, content, error_msg, timed_out
      INTO v_status_code, v_body_text, v_err, v_timed_out
      FROM net._http_response
     WHERE id = v_request_id;
    EXIT WHEN v_status_code IS NOT NULL OR v_err IS NOT NULL OR v_timed_out IS TRUE;
    PERFORM pg_sleep(1);
    v_attempts := v_attempts + 1;
  END LOOP;

  -- Diagnose the outcome in priority order
  IF v_timed_out IS TRUE THEN
    RAISE EXCEPTION '% timed out (pg_net): request_id=%, waited=%s',
      p_handler_name, v_request_id, v_attempts;
  END IF;

  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION '% HTTP error: % (request_id=%)',
      p_handler_name, v_err, v_request_id;
  END IF;

  IF v_status_code IS NULL THEN
    RAISE EXCEPTION '% did not respond within % seconds (request_id=%). Background job may still be running; check edge function logs.',
      p_handler_name, p_max_wait_seconds, v_request_id;
  END IF;

  -- Parse response body if it looks like JSON
  BEGIN
    v_response_json := v_body_text::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_response_json := jsonb_build_object('raw', LEFT(v_body_text, 4000));
  END;

  IF v_status_code >= 400 THEN
    RAISE EXCEPTION '% returned HTTP %: %',
      p_handler_name,
      v_status_code,
      COALESCE(
        v_response_json->>'error',
        v_response_json->>'output_summary',
        LEFT(v_body_text, 400)
      );
  END IF;

  -- Success — surface what the edge function actually reported
  RETURN jsonb_build_object(
    'records_processed', COALESCE((v_response_json->>'records_processed')::int, 0),
    'output_summary',    COALESCE(
                            v_response_json->>'output_summary',
                            p_handler_name || ' completed (no summary)'
                         ),
    'request_id',        v_request_id,
    'http_status',       v_status_code
  );
END;
$$;

REVOKE ALL ON FUNCTION public._dispatch_and_wait(uuid, text, jsonb, text, int) FROM PUBLIC;

-- 2) Rewrite dispatch_email_archiver to use synchronous wait
CREATE OR REPLACE FUNCTION public.dispatch_email_archiver(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_supabase_url text;
  v_secret       text;
BEGIN
  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;

  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  RETURN public._dispatch_and_wait(
    p_agency_id,
    v_supabase_url || '/functions/v1/email-archiver',
    jsonb_build_object(
      'agency_id',     p_agency_id::text,
      'recipe_id',     p_recipe_id::text,
      'shared_secret', v_secret
    ),
    'email-archiver',
    90
  );
END;
$$;

-- 3) Rewrite dispatch_document_processor to use synchronous wait
CREATE OR REPLACE FUNCTION public.dispatch_document_processor(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_supabase_url text;
  v_secret       text;
BEGIN
  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;

  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  RETURN public._dispatch_and_wait(
    p_agency_id,
    v_supabase_url || '/functions/v1/document-processor',
    jsonb_build_object(
      'agency_id',     p_agency_id::text,
      'shared_secret', v_secret
    ),
    'document-processor',
    90
  );
END;
$$;

-- 4) Trigger: auto-create / resolve alerts based on automation_run_log rows
CREATE OR REPLACE FUNCTION public.fn_alert_on_recipe_run()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_recipe_name  text;
  v_existing_id  uuid;
  v_msg          text;
BEGIN
  -- Skip for non-terminal statuses
  IF NEW.status NOT IN ('success','failed') THEN
    RETURN NEW;
  END IF;

  -- SUCCESS: auto-resolve any open automation_failure alerts for this recipe
  IF NEW.status = 'success' THEN
    UPDATE public.alerts
    SET    is_resolved = TRUE, resolved_at = NOW()
    WHERE  agency_id        = NEW.agency_id
      AND  module_reference = 'automations'
      AND  alert_type       = 'automation_failure'
      AND  related_id       = NEW.recipe_id
      AND  is_resolved      = FALSE;
    RETURN NEW;
  END IF;

  -- FAILED: collapse into one open alert per recipe
  SELECT recipe_name INTO v_recipe_name
  FROM   public.automation_recipes
  WHERE  id = NEW.recipe_id;

  v_msg := COALESCE(
    NEW.error_message,
    NEW.output_summary,
    'Recipe failed with no error message'
  );

  SELECT id INTO v_existing_id
  FROM   public.alerts
  WHERE  agency_id        = NEW.agency_id
    AND  module_reference = 'automations'
    AND  alert_type       = 'automation_failure'
    AND  related_id       = NEW.recipe_id
    AND  is_resolved      = FALSE
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    -- Update the open alert with the latest error + bump created_at so it sorts to top
    UPDATE public.alerts
    SET    message    = v_msg,
           created_at = NOW()
    WHERE  id = v_existing_id;
  ELSE
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, related_id, is_read, is_resolved, created_at
    ) VALUES (
      NEW.agency_id,
      'automation_failure',
      'warning',
      'Recipe failed: ' || COALESCE(v_recipe_name, '(unknown recipe)'),
      v_msg,
      'automations',
      NEW.recipe_id,
      FALSE,
      FALSE,
      NOW()
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_alert_on_recipe_run ON public.automation_run_log;
CREATE TRIGGER trg_alert_on_recipe_run
  AFTER INSERT ON public.automation_run_log
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_alert_on_recipe_run();

