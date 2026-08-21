INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup No-Send Check — Fri 7 PM CT',
  'No-send check — fires once per week Fri 7 PM CT (cron 0 0 * * 6 UTC, DST-correct for CDT; CST winter shifts to 6 PM CT — same DST caveat as sibling wrap-up ingest recipes). Runs document-processor mode=no_send_check: emails each teammate with wrapup_text IS NULL for current week (To: teammate SF, Cc: Peter SF) + sends ONE group Telegram to PJS Agency via pjsagencybot naming missing teammates. Hash-throttled via wrapup_nag_log (missing_items=[__NO_SEND__]). Body.dry_run=true supported. is_active flip requires Peter approval AND doc-processor bundle rebuild + deploy.',
  'cron',
  '0 0 * * 6',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"no_send_check"}'::jsonb,
  false
);
