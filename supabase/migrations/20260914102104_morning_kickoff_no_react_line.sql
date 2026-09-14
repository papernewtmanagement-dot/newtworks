-- Peter 2026-09-14: the morning kickoff does not need a react. The read-receipt
-- line stays on midday and EOD, where the :15 nag reads team_checkin_acks.
CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_quote record; v_last_eod_date date; v_block record; v_calls_block text;
  v_calls_days_back int; v_pending_votes int; v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
  v_today_week_end date; v_last_eod_week_end date; v_header_label text;
  v_prior_outcome record; v_outcome_line text; v_prior_eod_summary_msg_id bigint;
  v_commits text; v_checklist text;
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
    v_text := '🌅 ';

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

    -- Daily team checklist bridge (Peter 2026-09-11): yesterday's open team items
    -- and the running at-risk count for this CPR week. On the first workday of a
    -- new CPR week it reports last week's final CPR audit instead. Same text shows
    -- on the Daily Kickoff page through kickoff_morning_message().
    v_checklist := public.render_daily_checklist_bridge(p_agency_id, v_today);
    IF v_checklist IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_checklist;
    END IF;

    IF v_last_eod_date IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN
      v_text := v_text || E'\n' || v_block.encouragement_text;
    END IF;

  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday - Wk Quotes/Qtr SP';
  ELSE
    v_text := E'🌙 EOD - Wk Quotes/Qtr SP';
  END IF;

  -- Today's commits ride on the midday and EOD reminders (Peter 2026-09-11).
  IF v_checkin_type IN ('midday', 'eod') THEN
    v_commits := public.render_daily_commits_block(p_agency_id, v_today, false, v_checkin_type = 'eod');
    IF v_commits IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_commits;
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > NOW();

  IF v_pending_votes > 0 THEN
    IF v_pending_votes = 1 THEN v_text := v_text || E'\n\n🗳️ Vote Required';
    ELSE v_text := v_text || E'\n\n🗳️ Vote Required (' || v_pending_votes::text || ')'; END IF;
  END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := v_text || E'\n\n🏃 Remember health! Check in at 7 pm.';
  END IF;

  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  -- LOCKED (Peter 2026-09-10): the morning kickoff replaces the prior EOD summary.
  IF v_checkin_type = 'morning' THEN
    SELECT compile_results_message_id INTO v_prior_eod_summary_msg_id
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id AND checkin_type = 'eod'
      AND checkin_date < v_today AND compile_results_message_id IS NOT NULL
    ORDER BY checkin_date DESC LIMIT 1;
    IF v_prior_eod_summary_msg_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_prior_eod_summary_msg_id);
    END IF;
  END IF;

  -- Proof of reading (Peter 2026-09-11). The nag at :15 reads team_checkin_acks.
  -- Midday and EOD only — the morning kickoff does not need a react (Peter 2026-09-14).
  IF v_checkin_type IN ('midday', 'eod') THEN
    v_text := v_text || E'\n\n👍 React when you have read this.';
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
$function$;