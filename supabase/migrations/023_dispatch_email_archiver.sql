-- =========================================================================
-- Migration 023: dispatch_email_archiver
-- =========================================================================
-- Mirrors dispatch_document_processor (migration 021). The recipe row sets
-- composio_action='INTERNAL' and internal_handler='dispatch_email_archiver',
-- so run_internal_recipe() routes here, which fire-and-watches the
-- email-archiver Edge Function.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.dispatch_email_archiver(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_supabase_url  text;
  v_secret        text;
  v_request_id    bigint;
BEGIN
  v_supabase_url := public.get_setting(p_agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', p_agency_id;
  END IF;

  v_secret := public.get_setting(p_agency_id, 'automation_runner_cron_secret');
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', p_agency_id;
  END IF;

  -- Fire-and-watch: 4 minute timeout. Per-message Composio calls (find folder,
  -- create folder, fetch message, fetch attachment, upload to Drive, batch
  -- modify labels) accumulate fast on a backlog. The Edge Function caps
  -- itself at 5000 messages per run to stay well under this.
  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/email-archiver',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id', p_agency_id::text,
      'recipe_id', p_recipe_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  -- Synchronous response from the async dispatch -- actual numbers land in
  -- automation_run_log when the Edge Function calls back via the runner path.
  -- Since we go direct-to-edge (bypassing the runner) the Edge Function
  -- response carries the truth; this RETURN value is just the dispatch
  -- acknowledgement that run_internal_recipe will log.
  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched email-archiver (request_id ' || v_request_id || '). Check Edge Function logs or documents table for actual results.',
    'request_id', v_request_id
  );
END;
$function$;
