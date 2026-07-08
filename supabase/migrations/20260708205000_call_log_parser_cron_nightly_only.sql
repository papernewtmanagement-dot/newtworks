-- Migration: call_log_parser_cron_nightly_only
-- Applied: 2026-07-08 (correction)
--
-- Original recipe registered with cron `17 * * * *` (hourly at :17) which
-- was wasteful — eGain Daily Call Log email arrives once nightly via a
-- forwarding rule. Change to `30 5,6 * * *` (12:30 AM CT, DST-safe pair;
-- idempotent parser makes wrong-DST-hour fire a no-op).

UPDATE public.automation_recipes
SET cron_expression = '30 5,6 * * *',
    recipe_description = 'Parses eGain "Extension Activity.htm" attachments from statefarm.com Daily Call Log emails; upserts per-team-member daily metrics into daily_call_activity. Fires once nightly at 12:30 AM CT (DST-safe via 5:30/6:30 UTC pair; parser is idempotent so the wrong-DST-hour fire is a no-op). Morning check-in reads yesterday''s block via render_daily_calls_block().',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Call Log Parser (eGain daily intake)';
