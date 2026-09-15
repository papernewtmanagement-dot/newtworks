-- Telegram check-in rebuild (Peter spec 2026-09-14), wiring.

-- Hourly automation tick now calls the working weekend sweep.
SELECT cron.alter_job(
  1,
  command => $cmd$
    SELECT public.run_due_automation_recipes();
    SELECT public.resweep_failed_automation_dispatches();
    SELECT public.team_checkin_sweep_weekend_eod();
  $cmd$
);

DROP FUNCTION IF EXISTS public.team_checkin_sweep_stale_eod_summaries();

-- Check-in minute tick: the only minutes still in use are :00 (the 12:00 and
-- 17:00 messages and the +60 retire), :20 and :40 (the two nags), and :25 (the
-- 8:25 kickoff). :15, :30 and :50 are dead now that there is no compile step.
SELECT cron.alter_job(
  23,
  schedule => '0,20,25,40 0,13,14,17,18,19,22,23 * * 1-6'
);

-- No summary or compile message for midday or EOD any more.
UPDATE public.automation_recipes
SET is_active = false, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results';

-- First nag fires at +20, not +15.
UPDATE public.automation_recipes
SET cron_expression = '20 12 * * 1-5',
    input_config = input_config || '{"local_time":"12:20"}'::jsonb,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'midday';

UPDATE public.automation_recipes
SET cron_expression = '20 17 * * 1-5',
    input_config = input_config || '{"local_time":"17:20"}'::jsonb,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'eod';