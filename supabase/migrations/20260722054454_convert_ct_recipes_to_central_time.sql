-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 05:44:54 UTC (ledger name: convert_ct_recipes_to_central_time) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722054454.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ═══════════════════════════════════════════════════════════════════════
-- CONVERT CT-INTENT RECIPES TO CENTRAL-TIME-NATIVE + timezone='America/Chicago'
-- All cron_expression values below are now written in Central Time.
-- Postgres handles CDT/CST transitions natively via AT TIME ZONE.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Wrap-up trio — clean up
-- Delete the two supplement recipes (no longer needed; timezone handles DST)
DELETE FROM public.automation_recipes
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name IN (
    'Weekly Wrapup Ingest — Friday PM (CST winter supplement)',
    'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows (CST winter supplement)'
  );

-- Row A: Fri 3-6:30 PM CT (8 fires) — was `0,30 20-23 * * 5` UTC
UPDATE public.automation_recipes
SET cron_expression = '0,30 15-18 * * 5',
    timezone = 'America/Chicago',
    recipe_description = 'Wrap-up ingest — Fri 3:00, 3:30, 4:00, 4:30, 5:00, 5:30, 6:00, 6:30 PM CT (8 fires). Runs document-processor mode=wrapup: Gmail fetch, sender/week resolve, LLM organize into six-item rubric, upsert weekly_cpr_team_detail.wrapup_text, hash-throttled nag send on missing items. Timezone America/Chicago — Postgres handles DST natively. is_active flip requires Peter approval + doc-processor bundle deploy.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';

-- Row B (rename): Fri 7 PM CT only (1 fire) — extracted from old Row B
UPDATE public.automation_recipes
SET recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM',
    cron_expression = '0 19 * * 5',
    timezone = 'America/Chicago',
    recipe_description = 'Wrap-up ingest — Fri 7:00 PM CT (1 fire, final Fri window). Runs document-processor mode=wrapup. Timezone America/Chicago — Postgres handles DST natively. Companion recipes: "Weekly Wrapup Ingest — Fri PM" (earlier windows) + "Weekly Wrapup Ingest — Saturday" (Sat windows). is_active flip requires Peter approval + doc-processor bundle deploy.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

-- Row D (new): Saturday windows (3 fires) — split out from old Row B
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Saturday',
  'Wrap-up ingest — Sat 8:00 AM, 1:00 PM, 6:00 PM CT (3 fires). Runs document-processor mode=wrapup. Timezone America/Chicago — Postgres handles DST natively. Companion recipes: "Weekly Wrapup Ingest — Fri PM" (Fri 3-6:30 PM) + "Weekly Wrapup Ingest — Fri 7 PM" (Fri 7 PM). is_active flip requires Peter approval + doc-processor bundle deploy.',
  'cron',
  '0 8,13,18 * * 6',
  'America/Chicago',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb,
  false
);

-- Row C: no-send check Fri 7:02 PM CT (2-min buffer after ingest)
UPDATE public.automation_recipes
SET cron_expression = '2 19 * * 5',
    timezone = 'America/Chicago',
    recipe_description = 'No-send check — Fri 7:02 PM CT (1 fire, 2-min buffer after the Fri 7 PM ingest). Runs document-processor mode=no_send_check: emails each teammate with wrapup_text IS NULL for current week (To: teammate SF, Cc: Peter SF) + sends ONE group Telegram to PJS Agency via pjsagencybot naming missing teammates. Hash-throttled via wrapup_nag_log (missing_items=[__NO_SEND__]). Body.dry_run=true supported. Timezone America/Chicago — Postgres handles DST natively. is_active flip requires Peter approval + doc-processor bundle deploy.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup No-Send Check — Fri 7 PM CT';

-- ── 2) All other CT-intent active recipes → CT-native + tz='America/Chicago'
-- Payroll nag
UPDATE public.automation_recipes SET cron_expression = '0 7 * * 0-3', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Payroll Weekly Nag';

-- PFA nag
UPDATE public.automation_recipes SET cron_expression = '0 7 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'PFA Monthly Nag';

-- PFA reconciliation
UPDATE public.automation_recipes SET cron_expression = '0 12 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'PFA Monthly Reconciliation';

-- Agency snapshot Gmail parse (Fri 3:30 PM CT)
UPDATE public.automation_recipes SET cron_expression = '30 15 * * 5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Agency Snapshot - Gmail Parse';

-- Agency snapshot manual alert (Sat 9 AM CT)
UPDATE public.automation_recipes SET cron_expression = '0 9 * * 6', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Agency Snapshot - Manual Entry Alert';

-- Call log parser (12:30 AM CT)
UPDATE public.automation_recipes SET cron_expression = '30 0 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Call Log Parser (eGain daily intake)';

-- Daily briefing (7 AM CT)
UPDATE public.automation_recipes SET cron_expression = '0 7 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Daily Briefing Email';

-- License reminder (7:05 AM CT)
UPDATE public.automation_recipes SET cron_expression = '5 7 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Daily License Reminder Dispatcher';

-- Health check-ins (weekday)
UPDATE public.automation_recipes SET cron_expression = '0 19 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Health Checkin — Weekday Prompt';
UPDATE public.automation_recipes SET cron_expression = '0 20 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Health Checkin — Weekday Compile';

-- Health check-ins (Saturday)
UPDATE public.automation_recipes SET cron_expression = '0 21 * * 6', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Health Checkin — Saturday Prompt';
UPDATE public.automation_recipes SET cron_expression = '0 22 * * 6', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Health Checkin — Saturday Compile';

-- Team check-ins
UPDATE public.automation_recipes SET cron_expression = '25 8 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Morning Reminder';
UPDATE public.automation_recipes SET cron_expression = '0 12 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Midday Reminder';
UPDATE public.automation_recipes SET cron_expression = '15 12 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Midday Tag Missing';
UPDATE public.automation_recipes SET cron_expression = '30 12 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Midday Compile';
UPDATE public.automation_recipes SET cron_expression = '0 17 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — EOD Reminder';
UPDATE public.automation_recipes SET cron_expression = '15 17 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — EOD Tag Missing';
UPDATE public.automation_recipes SET cron_expression = '30 17 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — EOD Compile';

-- Monthly close
UPDATE public.automation_recipes SET cron_expression = '0 9 1 * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Monthly Close Checklist Generator';
UPDATE public.automation_recipes SET cron_expression = '0 9 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Monthly Close Monitor';

-- Leslie monthly check-in
UPDATE public.automation_recipes SET cron_expression = '0 9 1 * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Leslie Monthly Goals Check-in';

-- Producer watchers
UPDATE public.automation_recipes SET cron_expression = '0 9 * * 1', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Producer Complacency Watcher';
UPDATE public.automation_recipes SET cron_expression = '0 7 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Producer Underperformance Watcher';

-- Weekly rollups
UPDATE public.automation_recipes SET cron_expression = '59 23 * * 6', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Quarter Close — prize cart carry + budget + MVP snapshot';
UPDATE public.automation_recipes SET cron_expression = '59 23 * * 6', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly CPR — Saturday Outcome Writer';
UPDATE public.automation_recipes SET cron_expression = '0 15 * * 0', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Standing Time Off Materialize (Sunday)';
UPDATE public.automation_recipes SET cron_expression = '0 7 * * 0', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Cash Pulse';
UPDATE public.automation_recipes SET cron_expression = '0 7 * * 5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Cash Snapshot';
UPDATE public.automation_recipes SET cron_expression = '0 7 * * 0', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Weekly Team Trajectory Summaries';

-- Financial writers (mid-morning CT)
UPDATE public.automation_recipes SET cron_expression = '0 11 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'GL Entry Writer';
UPDATE public.automation_recipes SET cron_expression = '15 11 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Payroll GL Writer';
UPDATE public.automation_recipes SET cron_expression = '30 11 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Bank GL Writer';
UPDATE public.automation_recipes SET cron_expression = '45 11 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Credit Card GL Writer';

-- Transaction coding mailer
UPDATE public.automation_recipes SET cron_expression = '0 9 * * *', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Transaction Coding Question Mailer';

-- Inactive CT-intent recipes (convert too so they're correct when Peter reactivates)
UPDATE public.automation_recipes SET cron_expression = '40 8 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Morning Compile';
UPDATE public.automation_recipes SET cron_expression = '30 8 * * 1-5', timezone = 'America/Chicago'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Team Checkin — Morning Tag Missing';

-- ── 3) Delete the DST-drift workaround infrastructure
SELECT cron.unschedule('ct-cron-dst-sync-daily');
DROP FUNCTION IF EXISTS public.apply_ct_cron_dst_sync();
