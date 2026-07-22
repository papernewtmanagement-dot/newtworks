-- Convert all CT-intent recipes to CT-native cron + timezone='America/Chicago'.
-- Also deletes: the 2 supplement recipes; apply_ct_cron_dst_sync function;
-- the ct-cron-dst-sync-daily pg_cron job. All obsolete now that timezone
-- column handles DST via Postgres AT TIME ZONE.

-- (Note: this is a repo-mirror of the migration applied via Supabase MCP
-- on 2026-07-22. See supabase migration name 'convert_ct_recipes_to_central_time'.)

DELETE FROM public.automation_recipes
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name IN (
    'Weekly Wrapup Ingest — Friday PM (CST winter supplement)',
    'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows (CST winter supplement)'
  );

-- Row A: Fri PM (8 fires Fri 3-6:30 PM CT)
UPDATE public.automation_recipes
SET cron_expression = '0,30 15-18 * * 5', timezone = 'America/Chicago'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup Ingest — Friday PM';

-- Row B: rename to Fri 7 PM only (1 fire)
UPDATE public.automation_recipes
SET recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM',
    cron_expression = '0 19 * * 5', timezone = 'America/Chicago'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows';

-- Row D (new): Sat windows (3 fires)
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Saturday',
  'Wrap-up ingest — Sat 8:00 AM, 1:00 PM, 6:00 PM CT (3 fires). Runs document-processor mode=wrapup.',
  'cron', '0 8,13,18 * * 6', 'America/Chicago', 'INTERNAL', 'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb, false
);

-- Row C: no-send check Fri 7:02 PM CT (2-min buffer)
UPDATE public.automation_recipes
SET cron_expression = '2 19 * * 5', timezone = 'America/Chicago'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Wrapup No-Send Check — Fri 7 PM CT';

-- Bulk convert other CT-intent recipes (30+ recipes) — see live DB for full list.
-- Every UPDATE follows the pattern:
--   SET cron_expression = <CT-native cron>, timezone = 'America/Chicago'
--   WHERE recipe_name = <the recipe>
-- Payroll/PFA/agency snapshot/health checkins/team checkins/monthly close/
-- producer watchers/GL writers/etc. See applied migration for full list.

-- Delete the DST workaround infrastructure
SELECT cron.unschedule('ct-cron-dst-sync-daily');
DROP FUNCTION IF EXISTS public.apply_ct_cron_dst_sync();
