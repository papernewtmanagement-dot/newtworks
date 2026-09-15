-- Telegram check-in rebuild (Peter spec 2026-09-14), part 4 of 4.

-- Health reminder takes down the prior day's health summary, closing the chain:
-- kickoff removes the prior EOD, EOD removes the midday, health summary removes
-- the health reminder, health reminder removes yesterday's health summary.
CREATE OR REPLACE FUNCTION public.team_health_checkin_prompt(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_local_time text; v_chat_id bigint; v_today date;
  v_text text; v_response jsonb; v_message_id bigint; v_quote record;
  v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    IF public.team_checkin_is_within_recovery_window(v_local_time)
       AND NOT public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder') THEN
      v_is_recovery := true;
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
    END IF;
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

  SELECT quote_text, attribution, video_url INTO v_quote
  FROM public.health_quotes
  WHERE agency_id = p_agency_id AND is_active = true AND pool = 'health_eve'
  ORDER BY random() LIMIT 1;

  v_text := E'💪 Exercise today? X/5 or yes/no';

  IF v_quote.quote_text IS NOT NULL THEN
    v_text := v_text || E'\n\n"' || v_quote.quote_text || '"';
    IF v_quote.attribution IS NOT NULL THEN
      v_text := v_text || ' — ' || v_quote.attribution;
    END IF;
    IF v_quote.video_url IS NOT NULL THEN
      v_text := v_text || E'\n▶️ ' || v_quote.video_url;
    END IF;
  END IF;

  -- Take down the prior day's health summary (Peter 2026-09-14).
  PERFORM public.team_checkin_delete_message(
    p_agency_id, v_chat_id, 'health_eve', 'summary', NULL, v_today);

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (p_agency_id, v_today, 'health_eve', now(), v_message_id, v_text)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('health_eve prompt sent%s (msg_id=%s)',
      CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_message_id));
END;
$function$;


-- Weekend sweep. Friday's EOD message has no Monday kickoff inside Telegram's
-- 48-hour delete window, so it comes down Sunday afternoon instead.
-- The old function guarded on "no morning kickoff after this EOD", which
-- Saturday's kickoff always satisfied, so it never deleted anything.
CREATE OR REPLACE FUNCTION public.team_checkin_sweep_weekend_eod()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_local timestamp; v_row record; v_chat_id bigint;
  v_deleted int := 0; v_msg bigint;
BEGIN
  BEGIN
    v_local := (now() AT TIME ZONE 'America/Chicago');

    IF extract(dow FROM v_local)::int <> 0 THEN
      RETURN jsonb_build_object('deleted', 0, 'skipped', 'not Sunday');
    END IF;
    -- Friday EOD goes out at 5 pm. Telegram stops allowing the delete 48 hours
    -- later, at 5 pm Sunday, so the last safe ticks are 3 pm and 4 pm.
    IF extract(hour FROM v_local)::int NOT BETWEEN 15 AND 16 THEN
      RETURN jsonb_build_object('deleted', 0, 'skipped', 'outside the 3-5 pm window');
    END IF;

    FOR v_row IN
      SELECT DISTINCT r.agency_id
      FROM public.team_checkin_runs r
      WHERE r.checkin_type = 'eod'
        AND r.reminder_message_id IS NOT NULL
        AND r.checkin_date >= v_local::date - 3
    LOOP
      SELECT setting_value::bigint INTO v_chat_id FROM public.settings
      WHERE agency_id = v_row.agency_id AND setting_key = 'telegram_team_group_chat_id';

      v_msg := public.team_checkin_delete_message(
        v_row.agency_id, v_chat_id, 'eod', 'reminder', NULL, v_local::date);
      IF v_msg IS NOT NULL THEN v_deleted := v_deleted + 1; END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    -- Never raise: this rides the hourly automation tick.
    RETURN jsonb_build_object('deleted', v_deleted, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object('deleted', v_deleted);
END;
$function$;

COMMENT ON FUNCTION public.team_checkin_sweep_weekend_eod() IS
'Sunday 3-5 pm CT: deletes the last standing EOD check-in message. Replaces team_checkin_sweep_stale_eod_summaries, whose guard never matched. Peter spec 2026-09-14.';