-- One-time transition fix. Today ran on the old flow, so the message still
-- standing in Telegram is the EOD summary, not the EOD check-in message. Move
-- its id into the reminder slot so tomorrow's kickoff takes it down under the
-- new chain, and blank every id that Telegram has already deleted or that is
-- from the run of message ids that reset on 2026-09-12.
UPDATE public.team_checkin_runs
SET reminder_message_id = compile_results_message_id,
    compile_results_message_id = NULL,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND checkin_date = '2026-09-14' AND checkin_type = 'eod';

UPDATE public.team_checkin_runs
SET reminder_message_id = NULL,
    compile_results_message_id = NULL,
    tag_missing_message_id = NULL,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (
    (checkin_date = '2026-09-14' AND checkin_type = 'midday')
    OR checkin_date <= '2026-09-11'
  );