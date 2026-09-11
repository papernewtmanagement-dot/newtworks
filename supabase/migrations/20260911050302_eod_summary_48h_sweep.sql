-- Telegram only lets a bot delete a message for 48 hours after it was sent
-- (core.telegram.org/bots/api#deletemessage). Monday's kickoff comes about 63 hours
-- after Friday's EOD summary, so it can't delete it. This sweep catches that case
-- (and any holiday gap): an EOD summary with no kickoff after it is deleted in its
-- last two hours of deletability. On normal weeknights the kickoff has already
-- handled it and the sweep skips it. Peter 2026-09-10, part of the LOCKED
-- "kickoff replaces the prior EOD summary" rule.
CREATE OR REPLACE FUNCTION public.team_checkin_sweep_stale_eod_summaries()
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_row record;
  v_chat_id bigint;
  v_deleted int := 0;
BEGIN
  FOR v_row IN
    SELECT r.agency_id, r.checkin_date, r.compile_results_message_id
    FROM public.team_checkin_runs r
    WHERE r.checkin_type = 'eod'
      AND r.compile_results_message_id IS NOT NULL
      AND r.compile_results_at BETWEEN now() - interval '48 hours' AND now() - interval '46 hours'
      AND NOT EXISTS (
        SELECT 1 FROM public.team_checkin_runs m
        WHERE m.agency_id = r.agency_id AND m.checkin_type = 'morning'
          AND m.reminder_sent_at > r.compile_results_at)
  LOOP
    SELECT setting_value::bigint INTO v_chat_id FROM public.settings
    WHERE agency_id = v_row.agency_id AND setting_key = 'telegram_team_group_chat_id';
    IF v_chat_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_row.compile_results_message_id);
      v_deleted := v_deleted + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('deleted', v_deleted);
END;
$function$;

SELECT cron.unschedule('team_checkin_stale_eod_sweep')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'team_checkin_stale_eod_sweep');
SELECT cron.schedule('team_checkin_stale_eod_sweep', '35 * * * *',
  'SELECT public.team_checkin_sweep_stale_eod_summaries();');