-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 03:14:12 UTC (ledger name: v39_fold_call_log_parser_into_document_processor) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709031412.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Migration: fold call-log-parser into document-processor (v39, 2026-07-08)
--
-- 1. Modify dispatch_document_processor to merge recipe input_config into POST body.
--    Backward-compatible: null input_config → unchanged behavior.
-- 2. Update Call Log Parser recipe to use dispatch_document_processor + mode=call_log.
-- 3. Drop dispatch_call_log_parser (no longer referenced).

CREATE OR REPLACE FUNCTION public.dispatch_document_processor(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url          text;
  v_secret       text;
  v_input_config jsonb;
  v_request_id   bigint;
  v_body         jsonb;
BEGIN
  SELECT setting_value INTO v_url FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'supabase_url missing from settings for agency %', p_agency_id;
  END IF;
  v_url := v_url || '/functions/v1/document-processor';

  SELECT setting_value INTO v_secret FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret missing from settings for agency %', p_agency_id;
  END IF;

  -- Merge recipe input_config into POST body so recipes can pass mode/query/max_results.
  -- Existing recipes with NULL input_config are unaffected.
  SELECT COALESCE(input_config, '{}'::jsonb) INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_body := jsonb_build_object(
              'agency_id', p_agency_id,
              'shared_secret', v_secret
            ) || v_input_config;

  SELECT net.http_post(
    url     := v_url,
    body    := v_body,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 300000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'target_function', 'document-processor',
    'mode', COALESCE(v_input_config->>'mode', 'attachments'),
    'output_summary', format('Dispatched document-processor mode=%s (request_id %s).',
                             COALESCE(v_input_config->>'mode', 'attachments'), v_request_id),
    'records_processed', 0
  );
END;
$function$;

-- Point Call Log Parser recipe to unified dispatcher with mode=call_log
UPDATE public.automation_recipes
SET internal_handler = 'dispatch_document_processor',
    input_config = '{"mode":"call_log"}'::jsonb,
    updated_at = NOW()
WHERE id = '6056ce64-6b1a-4ce6-a05f-b85b93038dec';

-- Drop the no-longer-referenced dispatcher
DROP FUNCTION IF EXISTS public.dispatch_call_log_parser(uuid, uuid);
