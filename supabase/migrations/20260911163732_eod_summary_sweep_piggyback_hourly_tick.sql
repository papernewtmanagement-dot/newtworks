-- Peter 2026-09-10 (later): bring back the Friday EOD cleanup, but no job of its own.
-- It rides on the existing hourly automation tick. Friday's EOD summary stays up over
-- the weekend and comes down Sunday about 3:30-5:30 pm, inside Telegram's 48-hour
-- delete limit, so Monday's kickoff lands in a clean channel. Weeknights the kickoff
-- already deleted it, so this finds nothing.
-- The function never raises: it shares a transaction with the automation tick, and a
-- failure here must never roll back the automation runs.
CREATE OR REPLACE FUNCTION public.team_checkin_sweep_stale_eod_summaries()
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_row record;
  v_chat_id bigint;
  v_deleted int := 0;
BEGIN
  BEGIN
    FOR v_row IN
      SELECT r.agency_id, r.compile_results_message_id
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
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('deleted', v_deleted, 'error', SQLERRM);
  END;
  RETURN jsonb_build_object('deleted', v_deleted);
END;
$function$;

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'automation-runner-tick'),
  command := ' SELECT public.run_due_automation_recipes(); SELECT public.team_checkin_sweep_stale_eod_summaries(); ');