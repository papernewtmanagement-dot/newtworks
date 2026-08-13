-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 16:28:57 UTC (ledger name: team_checkin_time_corrections) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722162857.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Peter directive 2026-07-22: nag at 12:30, compile at 1 PM.
-- Applying same 30-min gap pattern to EOD (reminder→nag→compile at 5:00→5:30→6:00 PM CT).

UPDATE public.automation_recipes SET cron_expression = '30 12 * * 1-5'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Team Checkin — Midday Tag Missing';

UPDATE public.automation_recipes SET cron_expression = '0 13 * * 1-5'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Team Checkin — Midday Compile';

UPDATE public.automation_recipes SET cron_expression = '30 17 * * 1-5'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Team Checkin — EOD Tag Missing';

UPDATE public.automation_recipes SET cron_expression = '0 18 * * 1-5'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Team Checkin — EOD Compile';
