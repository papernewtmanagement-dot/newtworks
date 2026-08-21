-- Comment-only correction. Logic is byte-for-byte identical to the deployed
-- function; only the misleading comment block is rewritten to describe the
-- actual execution path: cron -> automation-runner (INTERNAL) ->
-- run_internal_recipe -> dispatch_email_archiver -> net.http_post to the
-- email-archiver Edge Function. The prior comment claimed "direct-to-edge
-- (bypassing the runner)", which was never true for an INTERNAL recipe.
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

  -- Execution path: pg_cron -> automation-runner (recipe is INTERNAL) ->
  -- run_internal_recipe(recipe_id) -> THIS function -> async net.http_post to
  -- the email-archiver Edge Function. The HTTP POST is fire-and-forget from
  -- here, so the Edge Function writes the real archive results (documents
  -- rows, INBOX-label removal) on its own; this RETURN is just the dispatch
  -- acknowledgement that run_internal_recipe logs to automation_run_log.
  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched email-archiver (request_id ' || v_request_id || '). Check Edge Function logs or documents table for actual results.',
    'request_id', v_request_id
  );
END;
$function$;
