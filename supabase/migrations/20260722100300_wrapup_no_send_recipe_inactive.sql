-- Stages the Fri-7-PM no-send check recipe INACTIVE.
-- Cron `0 0 * * 6` UTC = Fri 7 PM CT during CDT / Fri 6 PM CT during CST.
-- Single fire per week. Runs document-processor mode=no_send_check:
--   1. Query teammates whose wrapup_text IS NULL for current week's Saturday
--   2. Email each missing teammate (To: teammate SF, Cc: peter.story.yrru@statefarm.com)
--   3. Send ONE group Telegram to PJS Agency chat via pjsagencybot
-- Hash-throttled via wrapup_nag_log (missing_items=['__NO_SEND__']).
-- Supports body.dry_run=true for preview-only invocations.
--
-- RACE NOTE: this recipe's cron `0 0 * * 6` overlaps with the wrap-up ingest
-- recipe's Fri 7 PM tick (0 0,13,18,23 * * 6). If both fire at 00:00 UTC
-- simultaneously and a teammate emailed at 6:59 PM CT, no-send may read state
-- before ingest lands the write → false nag. If needed, shift to `2 0 * * 6`
-- for 2-min buffer at activation time.
--
-- is_active flip requires Peter approval AND bundle rebuild + edge fn deploy
-- (source wiring committed but bundle not yet rebuilt, so this recipe cannot
-- actually fire until the bundle catches up).

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
