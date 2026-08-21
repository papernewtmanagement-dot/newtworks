-- try_send_weekly_cpr_recap: support Sat/Sun/Mon 6 AM CT schedule with DST skip guard.
-- v_week_end logic unchanged (already maps all three days to same Saturday row).
-- Adds: (a) DST guard that silently skips when CT hour != 6, matching the wrong-DST
-- skip pattern used by Outcome Writer; (b) day-of-week-aware day labels and retry notes
-- for Sat/Sun/Mon (was Sat/non-Sat).

CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id    uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id    uuid;
  v_run_started  timestamptz := now();
  v_now_ct       timestamp;
  v_today_ct     date;
  v_hour_ct      int;
  v_week_end     date;
  v_dow          int;          -- 0=Sun 1=Mon ... 6=Sat (CT)
  v_report       record;
  v_send_res     jsonb;
  v_status       text;
  v_err          text;
  v_result       jsonb;
  v_skip_reason  text;
  v_peter_chat   bigint;
  v_tg_msg       text;
  v_tg_resp      jsonb;
  v_day_label    text;
  v_retry_note   text;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_auto_send' LIMIT 1;

  v_now_ct      := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct    := v_now_ct::date;
  v_hour_ct     := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow         := EXTRACT(DOW FROM v_today_ct)::int;

  -- DST GUARD. pg_cron fires at both 11:00 and 12:00 UTC to cover CDT and CST.
  -- One fire each day will be 6 AM CT (correct); the other will be 5 AM or 7 AM (wrong-DST).
  -- Skip the wrong-DST fire silently — no Telegram alert, log success.
  IF v_hour_ct <> 6 THEN
    v_result := jsonb_build_object('skipped', 'wrong_dst_cron_fire', 'hour_ct', v_hour_ct);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'success',
            'Skipped: wrong-DST cron fire (intended 6 AM CT, got hour ' || v_hour_ct || ')',
            EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  -- Day-of-week-aware labels + retry notes for Sat/Sun/Mon morning chain.
  v_day_label := CASE v_dow
    WHEN 6 THEN 'Sat'
    WHEN 0 THEN 'Sun'
    WHEN 1 THEN 'Mon'
    ELSE 'Day' || v_dow::text
  END;
  v_retry_note := CASE v_dow
    WHEN 6 THEN ' Sun + Mon backups will retry.'
    WHEN 0 THEN ' Mon backup will retry.'
    WHEN 1 THEN ' No further auto-retry — manual send needed.'
    ELSE ''
  END;

  -- Week-end resolution (unchanged):
  -- Sat dow=6: week_end = today (current Sat row).
  -- Sun dow=0: week_end = yesterday (same Sat row).
  -- Mon dow=1: week_end = 2 days ago (same Sat row).
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    v_skip_reason := 'no_report_row';
    v_result := jsonb_build_object('fired', false, 'skipped', v_skip_reason, 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSIF v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('fired', false, 'skipped', 'already_sent', 'sent_to_team_at', v_report.sent_to_team_at);
    v_status := 'skipped';
    v_skip_reason := NULL;
  ELSIF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    v_skip_reason := 'opener_not_ready';
    v_result := jsonb_build_object('fired', false, 'skipped', v_skip_reason, 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSIF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    v_skip_reason := 'looking_ahead_not_ready';
    v_result := jsonb_build_object('fired', false, 'skipped', v_skip_reason, 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSE
    v_send_res := public.send_weekly_cpr_recap(v_agency_id, v_week_end);
    v_result   := jsonb_build_object('fired', true, 'week_ending_date', v_week_end, 'send_result', v_send_res);
    IF (v_send_res->>'success')::boolean = true THEN
      v_status := 'success';
      v_skip_reason := NULL;
    ELSE
      v_status := 'failed';
      v_err    := v_send_res->>'error';
      v_skip_reason := 'send_failed';
    END IF;
  END IF;

  -- Telegram fallback: any non-success non-already_sent outcome
  IF v_skip_reason IS NOT NULL THEN
    BEGIN
      SELECT ttm.telegram_user_id INTO v_peter_chat
        FROM public.team_telegram_map ttm
        JOIN public.team t ON t.id = ttm.team_id
       WHERE t.agency_id = v_agency_id
         AND t.role_level = 'Owner'
         AND coalesce(ttm.is_excluded, false) = false
       LIMIT 1;

      IF v_peter_chat IS NOT NULL THEN
        v_tg_msg := CASE v_skip_reason
          WHEN 'no_report_row' THEN
            format(E'🚨 CPR auto-send (%s 6 AM CT) skipped\n\nNo weekly_cpr_reports row for week ending %s.%s',
                   v_day_label, v_week_end, v_retry_note)
          WHEN 'opener_not_ready' THEN
            format(E'⏳ CPR auto-send (%s 6 AM CT) skipped\n\nopener_text not ready for week ending %s.%s',
                   v_day_label, v_week_end, v_retry_note)
          WHEN 'looking_ahead_not_ready' THEN
            format(E'⏳ CPR auto-send (%s 6 AM CT) skipped\n\nlooking_next_week_text not ready for week ending %s.%s',
                   v_day_label, v_week_end, v_retry_note)
          WHEN 'send_failed' THEN
            format(E'🔴 CPR auto-send (%s 6 AM CT) FAILED\n\nWeek ending %s. Error: %s%s',
                   v_day_label, v_week_end, COALESCE(v_err,'unknown'), v_retry_note)
          ELSE
            format(E'⚠️ CPR auto-send (%s 6 AM CT) did not send\n\nWeek ending %s. Reason: %s%s',
                   v_day_label, v_week_end, v_skip_reason, v_retry_note)
        END;

        v_tg_resp := public.paper_newt_send_message(v_peter_chat, v_tg_msg);

        IF v_tg_resp IS NOT NULL AND (v_tg_resp->>'ok')::boolean IS TRUE THEN
          v_result := v_result || jsonb_build_object(
            'telegram_alert', 'sent',
            'telegram_message_id', v_tg_resp->'result'->>'message_id'
          );
        ELSE
          v_result := v_result || jsonb_build_object(
            'telegram_alert', 'failed',
            'telegram_error', v_tg_resp->>'description'
          );
        END IF;
      ELSE
        v_result := v_result || jsonb_build_object('telegram_alert', 'no_chat_id_for_owner');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_result := v_result || jsonb_build_object('telegram_alert', 'exception', 'telegram_exception', SQLERRM);
    END;
  END IF;

  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, v_status, v_err, v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  BEGIN
    SELECT ttm.telegram_user_id INTO v_peter_chat
      FROM public.team_telegram_map ttm
      JOIN public.team t ON t.id = ttm.team_id
     WHERE t.agency_id = v_agency_id
       AND t.role_level = 'Owner'
       AND coalesce(ttm.is_excluded, false) = false
     LIMIT 1;
    IF v_peter_chat IS NOT NULL THEN
      PERFORM public.paper_newt_send_message(
        v_peter_chat,
        format(E'🔴 CPR auto-send EXCEPTION\n\nFunction try_send_weekly_cpr_recap raised: %s', SQLERRM)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$function$;
