-- Peter 2026-09-10, second pass:
--  * Short instruction line back on the reminders ("Wk Quotes/Qtr SP").
--  * Health prompt states the answer format, quote underneath.
--  * Compile DELETES the reminder and posts a fresh message instead of editing in
--    place, so the team still gets the notification. Editing in place was silent.

CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_quote record; v_last_eod_date date; v_block record; v_calls_block text;
  v_calls_days_back int; v_pending_votes int; v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
  v_today_week_end date; v_last_eod_week_end date; v_header_label text;
  v_prior_outcome record; v_outcome_line text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    IF public.team_checkin_is_within_recovery_window(v_local_time)
       AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
      v_is_recovery := true;
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
    END IF;
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := '';

    SELECT quote_text, attribution, video_url INTO v_quote
    FROM public.health_quotes
    WHERE agency_id = p_agency_id AND is_active = true AND pool = 'morning_motivation'
    ORDER BY random() LIMIT 1;
    IF v_quote.quote_text IS NOT NULL THEN
      v_text := v_text || '"' || v_quote.quote_text || '"';
      IF v_quote.attribution IS NOT NULL THEN
        v_text := v_text || ' — ' || v_quote.attribution;
      END IF;
      IF v_quote.video_url IS NOT NULL THEN
        v_text := v_text || E'\n▶️ ' || v_quote.video_url;
      END IF;
      v_text := v_text || E'\n\n';
    END IF;

    SELECT max(checkin_date) INTO v_last_eod_date
    FROM public.team_checkins
    WHERE agency_id = p_agency_id AND checkin_type = 'eod' AND checkin_date < v_today;

    IF v_last_eod_date IS NOT NULL THEN
      v_today_week_end := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, v_today));
      v_last_eod_week_end := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, v_last_eod_date));

      IF v_last_eod_week_end < v_today_week_end THEN
        SELECT won_the_week, COALESCE(quotes_owed_next_week, 0) AS carryover
          INTO v_prior_outcome
        FROM public.weekly_cpr_reports
        WHERE agency_id = p_agency_id AND week_ending_date = v_last_eod_week_end;

        v_outcome_line := NULL;
        IF v_prior_outcome.won_the_week IS NOT NULL THEN
          IF v_prior_outcome.won_the_week THEN v_outcome_line := '🏆 Won last week';
          ELSE v_outcome_line := '❌ Missed last week'; END IF;
          IF v_prior_outcome.carryover > 0 THEN
            v_outcome_line := v_outcome_line
              || format(' — +%s quotes carryover into this week', v_prior_outcome.carryover);
          END IF;
        END IF;

        IF v_outcome_line IS NOT NULL THEN
          v_header_label := format(E'📊 EOD %s (last week close)\n%s',
                                    to_char(v_last_eod_date, 'Mon DD'), v_outcome_line);
        ELSE
          v_header_label := format('📊 EOD %s (last week close)', to_char(v_last_eod_date, 'Mon DD'));
        END IF;
      ELSE
        v_header_label := format('📊 EOD %s', to_char(v_last_eod_date, 'Mon DD'));
      END IF;

      SELECT * INTO v_block FROM public.render_team_status_block(
        p_agency_id, v_last_eod_date, 'eod', v_header_label, v_today);
      v_text := v_text || v_block.block_text;
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record yet.)';
    END IF;

    v_calls_block := NULL;
    FOR v_calls_days_back IN 1..4 LOOP
      v_calls_block := public.render_daily_calls_block(p_agency_id, v_today - v_calls_days_back);
      EXIT WHEN v_calls_block IS NOT NULL AND v_calls_block <> '';
    END LOOP;
    IF v_calls_block IS NOT NULL AND v_calls_block <> '' THEN
      v_text := v_text || E'\n' || v_calls_block;
    END IF;

    IF v_last_eod_date IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN
      v_text := v_text || E'\n' || v_block.encouragement_text;
    END IF;

  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday - Wk Quotes/Qtr SP';
  ELSE
    v_text := E'🌙 EOD - Wk Quotes/Qtr SP';
  END IF;

  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > NOW();

  IF v_pending_votes > 0 THEN
    IF v_pending_votes = 1 THEN v_text := v_text || E'\n\n🗳️ Vote Required';
    ELSE v_text := v_text || E'\n\n🗳️ Vote Required (' || v_pending_votes::text || ')'; END IF;
  END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := v_text || E'\n\n🏃 Get started on your health goal! We''ll check in at 7 pm.';
  END IF;

  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (p_agency_id, v_today, v_checkin_type, now(), v_message_id, v_text)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s reminder sent%s (msg_id=%s, dow=%s, pending_votes=%s)',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_message_id, v_dow, v_pending_votes));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_type_label text; v_block record; v_cpr_id uuid; v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
  v_wrapup_url text := 'https://newtworks.vercel.app/processes/1590689841';
  v_reminder_msg_id bigint; v_tag_msg_id bigint;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT reminder_message_id, tag_missing_message_id
    INTO v_reminder_msg_id, v_tag_msg_id
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  v_type_label := CASE v_checkin_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_checkin_type) END;

  v_cpr_id := public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, v_today, v_checkin_type,
    '📊 ' || v_type_label || ' ' || to_char(v_today, 'Mon DD'));
  v_text := v_block.block_text;

  IF v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  -- Reminder is about to be deleted, so anything that still needs saying moves
  -- onto the results message. Deposit records is the one (Peter 2026-09-10).
  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n📝 Weekly wrapup — email paper.newt.management@gmail.com. '
      || E'What to include: <a href="' || v_wrapup_url || E'">Daily Wrap-up</a>';
  END IF;

  -- Delete the reminder and the tag-missing nudge, then post the results fresh.
  -- Editing the reminder in place was tried 2026-09-10 and reverted the same day:
  -- an edit fires no notification, so the team never saw the numbers land.
  -- Delete-then-post keeps the channel to one bubble AND keeps the ping.
  IF v_reminder_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_reminder_msg_id);
  END IF;
  IF v_tag_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_tag_msg_id);
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      updated_at = now(),
      responders_count = v_block.fresh_count,
      expected_count = v_block.expected_count
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_block.fresh_count + v_block.carried_count,
    'output_summary', format('%s compile%s: %s/%s reporting; team %s/%s; cpr_id=%s',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_block.fresh_count, v_block.expected_count,
      v_block.team_total_quotes, v_block.team_total_sales, v_cpr_id));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.team_health_checkin_prompt(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
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
$fn$;