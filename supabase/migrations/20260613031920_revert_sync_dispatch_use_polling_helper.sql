
-- LESSON LEARNED: pg_net is "enqueue at commit". The HTTP POST doesn't fire
-- until the calling transaction commits. So a function can't synchronously
-- poll for its own response — and if the function exceptions, the request
-- gets rolled back. Revert dispatch_* functions to fire-and-forget (they
-- still return request_id in the result), and move the polling to the TS
-- runner where each poll is a separate RPC call = separate transaction.

CREATE OR REPLACE FUNCTION public.dispatch_email_archiver(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_supabase_url text;
  v_secret       text;
  v_request_id   bigint;
BEGIN
  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;
  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/email-archiver',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id',     p_agency_id::text,
      'recipe_id',     p_recipe_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched email-archiver (request_id ' || v_request_id || '). Awaiting response...',
    'request_id', v_request_id,
    'target_function', 'email-archiver'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.dispatch_document_processor(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_supabase_url text;
  v_secret       text;
  v_request_id   bigint;
BEGIN
  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;
  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/document-processor',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id',     p_agency_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched document-processor (request_id ' || v_request_id || '). Awaiting response...',
    'request_id', v_request_id,
    'target_function', 'document-processor'
  );
END;
$$;

-- Drop the failed sync helper — no longer needed
DROP FUNCTION IF EXISTS public._dispatch_and_wait(uuid, text, jsonb, text, int);

-- Helper for the TS runner to fetch pg_net responses, since the `net` schema
-- isn't exposed to PostgREST by default. Each call is its own transaction,
-- so it SEES pg_net's committed writes from the background worker.
CREATE OR REPLACE FUNCTION public.get_pg_net_response(p_request_id bigint)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'status_code', status_code,
    'content',     content,
    'error_msg',   error_msg,
    'timed_out',   timed_out,
    'created',     created
  )
  FROM net._http_response
  WHERE id = p_request_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_pg_net_response(bigint) TO service_role;
REVOKE EXECUTE ON FUNCTION public.get_pg_net_response(bigint) FROM anon, authenticated;

