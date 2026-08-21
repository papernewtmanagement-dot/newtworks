-- Restore dispatch_document_processor (migration 021 was lost from repo).
-- Mirrors dispatch_email_archiver (migration 023): fires the document-processor
-- Edge Function via net.http_post with the standard shared-secret payload.
CREATE OR REPLACE FUNCTION public.dispatch_document_processor(p_agency_id uuid, p_recipe_id uuid)
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

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/document-processor',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id', p_agency_id::text,
      'recipe_id', p_recipe_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched document-processor (request_id ' || v_request_id || '). See documents/journal_entries tables for actual results.',
    'request_id', v_request_id
  );
END;
$function$;
