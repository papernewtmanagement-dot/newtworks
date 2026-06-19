-- =========================================================================
-- Migration 027: Deterministic parsers infrastructure + pg_net response helper
-- =========================================================================
-- Three things this migration ships:
--   1. Gmail tracking columns on documents (so we can archive threads after
--      successful parsing).
--   2. public.get_pg_net_response(p_request_id bigint) -- restores the helper
--      the automation-runner edge function expects after dispatching pg_net
--      requests. Without it every dispatched recipe logs as failed even when
--      its underlying edge function ran fine.
--   3. public.dispatch_document_processor(...) -- restores the dispatch helper
--      that was lost from the repo (former migration 021). The function exists
--      in DB but had no migration backing it; this restores parity.
-- =========================================================================

-- 1) Gmail tracking columns on documents
ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS gmail_message_id text,
  ADD COLUMN IF NOT EXISTS gmail_thread_id  text,
  ADD COLUMN IF NOT EXISTS gmail_archived_at timestamp with time zone;

CREATE INDEX IF NOT EXISTS documents_gmail_thread_idx
  ON public.documents (gmail_thread_id)
  WHERE gmail_thread_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS documents_gmail_message_idx
  ON public.documents (gmail_message_id)
  WHERE gmail_message_id IS NOT NULL;


-- 2) get_pg_net_response: thin wrapper around net._http_response
-- The automation-runner edge function dispatches edge functions via
-- pg_net.http_post (async). After dispatch it polls this RPC to get the
-- actual response. The shape returned must match what the runner expects:
--   { status_code, content, error_msg, timed_out, created }
CREATE OR REPLACE FUNCTION public.get_pg_net_response(p_request_id bigint)
RETURNS TABLE (
  status_code integer,
  content     text,
  error_msg   text,
  timed_out   boolean,
  created     timestamp with time zone
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, net, pg_catalog
AS $$
  SELECT
    r.status_code,
    r.content::text,
    r.error_msg,
    -- net._http_response has no `timed_out` column on this version; emulate
    -- by always returning false. The runner only flips timed_out=true when
    -- the upstream HTTP layer reports a timeout, which shows up as a
    -- populated error_msg here anyway.
    false AS timed_out,
    r.created
  FROM net._http_response r
  WHERE r.id = p_request_id
$$;

GRANT EXECUTE ON FUNCTION public.get_pg_net_response(bigint) TO anon, authenticated, service_role;


-- 3) dispatch_document_processor: restores former migration 021
-- Pattern mirrors dispatch_email_archiver (migration 023). Fires the
-- document-processor edge function via pg_net.http_post and returns the
-- request_id so the automation-runner can poll get_pg_net_response.
CREATE OR REPLACE FUNCTION public.dispatch_document_processor(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, pg_catalog
AS $$
DECLARE
  v_url              text;
  v_secret           text;
  v_request_id       bigint;
BEGIN
  -- Edge function URL: <project_url>/functions/v1/document-processor
  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/document-processor';

  -- Shared secret for cron-only invocation
  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  -- Fire async HTTP POST. pg_net returns immediately with a request_id;
  -- the automation-runner polls get_pg_net_response(request_id) to learn the result.
  SELECT net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'agency_id', p_agency_id,
                 'shared_secret', v_secret
               ),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json'
               ),
    timeout_milliseconds := 300000  -- 5 minutes for slow Gmail intakes
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'target_function', 'document-processor',
    'output_summary', format('Dispatched document-processor (request_id %s). See documents/journal_entries tables for actual results.', v_request_id),
    'records_processed', 0
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.dispatch_document_processor(uuid, uuid) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_pg_net_response IS
  'Returns the pg_net async HTTP response by request_id. Called by automation-runner edge function after dispatching via pg_net.http_post.';
COMMENT ON FUNCTION public.dispatch_document_processor IS
  'Dispatches the document-processor edge function via pg_net (async). Returns request_id for automation-runner to poll.';
