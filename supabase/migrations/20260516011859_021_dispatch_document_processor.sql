-- =========================================================================
-- Migration 021: dispatch_document_processor
-- =========================================================================
-- Bridges the existing automation_recipes / pg_cron tick infrastructure to
-- the new document-processor Edge Function (deployed 2026-05-15, session 7).
--
-- WHY: run_due_automation_recipes() already ticks every minute via pg_cron
-- jobid=1 (automation-runner-tick), evaluates cron_expression against NOW(),
-- and dispatches via run_internal_recipe() when composio_action='INTERNAL'.
-- That helper takes an internal_handler string and invokes
-- public.<handler>(agency_id, recipe_id). This adds the handler.
--
-- The handler POSTs to the document-processor function URL with the
-- agency's shared_secret (automation_runner_cron_secret). The function is
-- deployed with verify_jwt=false; it authenticates via the secret in body.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.dispatch_document_processor(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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

  -- Fire-and-watch: 4 minute timeout. The function itself is fast when there's
  -- nothing to process; the worst case is many attachments needing LLM parsing.
  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/document-processor',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'agency_id', p_agency_id::text,
      'shared_secret', v_secret
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  -- Return shape matches what run_internal_recipe expects so the runner logs
  -- a tidy summary row. We can't synchronously observe the response from
  -- here (net.http_post is async), so we report dispatch only.
  RETURN jsonb_build_object(
    'records_processed', 0,
    'output_summary', 'Dispatched document-processor (request_id ' || v_request_id || '). See documents/journal_entries tables for actual results.',
    'request_id', v_request_id
  );
END;
$$;
