-- The kickoff body now has ONE builder, the same way midday and EOD share
-- team_checkin_build_results_message. It was inline in team_checkin_send_reminder,
-- which meant the text could not be rebuilt for a message already on Telegram
-- without copying the logic somewhere else (Peter 2026-09-15).
-- Returns the text with the {{commits}} marker still in it; kickoff_compose_message
-- swaps the marker for the live commits block at send time and on every refresh.
CREATE OR REPLACE FUNCTION public.kickoff_build_message(p_agency_id uuid, p_date date)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_text text := '🌅 ';
  v_quote record; v_prior_day date; v_block record; v_calls_block text;
  v_calls_days_back int; v_pending_votes int := 0;
  v_today_week_end date; v_prior_week_end date; v_header_label text;
  v_prior_outcome record; v_outcome_line text; v_checklist text;
BEGIN
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

  -- Prior workday. Same day the commits block and checklist bridge report on.
  v_prior_day := public.checklist_prev_workday(p_agency_id, p_date);

  IF v_prior_day IS NOT NULL THEN
    v_today_week_end := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, p_date));
    v_prior_week_end := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, v_prior_day));

    IF v_prior_week_end < v_today_week_end THEN
      -- First workday of a new week (normally Monday). Header carries the
      -- week-ending Saturday of the week that just closed, plus won or missed.
      SELECT won_the_week, COALESCE(quotes_owed_next_week, 0) AS carryover
        INTO v_prior_outcome
      FROM public.weekly_cpr_reports
      WHERE agency_id = p_agency_id AND week_ending_date = v_prior_week_end;

      v_outcome_line := NULL;
      IF v_prior_outcome.won_the_week IS NOT NULL THEN
        IF v_prior_outcome.won_the_week THEN v_outcome_line := '🏆 Won';
        ELSE v_outcome_line := '❌ Missed'; END IF;
        IF v_prior_outcome.carryover > 0 THEN
          v_outcome_line := v_outcome_line
            || format(' — +%s $Q carryover into this week', v_prior_outcome.carryover);
        END IF;
      END IF;

      v_header_label := format('📊 EOD %s%s',
        to_char(v_prior_week_end, 'Mon DD'),
        COALESCE(' ' || v_outcome_line, ''));
    ELSE
      -- Any other day: the prior day's date, no won or missed marker.
      v_header_label := format('📊 EOD %s', to_char(v_prior_day, 'Mon DD'));
    END IF;

    SELECT * INTO v_block FROM public.render_team_status_block(
      p_agency_id, v_prior_day, 'eod', v_header_label, p_date);
    v_text := v_text || v_block.block_text;
  ELSE
    v_text := v_text || E'(No prior EOD numbers on record yet.)';
  END IF;

  v_calls_block := NULL;
  FOR v_calls_days_back IN 1..4 LOOP
    v_calls_block := public.render_daily_calls_block(p_agency_id, p_date - v_calls_days_back);
    EXIT WHEN v_calls_block IS NOT NULL AND v_calls_block <> '';
  END LOOP;
  IF v_calls_block IS NOT NULL AND v_calls_block <> '' THEN
    v_text := v_text || E'\n' || v_calls_block;
  END IF;

  v_text := v_text || E'\n\n{{commits}}';

  v_checklist := public.render_daily_checklist_bridge(p_agency_id, p_date);
  IF v_checklist IS NOT NULL THEN
    v_text := v_text || E'\n\n' || v_checklist;
  END IF;

  IF v_prior_day IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > NOW();

  IF v_pending_votes = 1 THEN v_text := v_text || E'\n\n🗳️ Vote Required';
  ELSIF v_pending_votes > 1 THEN
    v_text := v_text || E'\n\n🗳️ Vote Required (' || v_pending_votes::text || ')';
  END IF;

  v_text := v_text || E'\n\n🏃 Remember health! Check in at 7 pm.';

  RETURN v_text;
END;
$function$;

CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_pending_votes int := 0; v_is_recovery boolean := false;
  v_parse_mode text := NULL; v_built record; v_expected int := NULL;
  v_send_text text;
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

  IF v_checkin_type IN ('midday', 'eod') THEN
    -- One builder for both (Peter 2026-09-14). No compile step follows.
    SELECT * INTO v_built
    FROM public.team_checkin_build_results_message(p_agency_id, v_checkin_type, v_today);
    v_text := v_built.message_text;
    v_parse_mode := v_built.parse_mode;
    v_expected := v_built.expected_count;

    -- The EOD message replaces the midday message.
    IF v_checkin_type = 'eod' THEN
      PERFORM public.team_checkin_delete_message(
        p_agency_id, v_chat_id, 'midday', 'reminder', v_today);
    END IF;

  ELSE
    -- Morning kickoff. One builder, shared with the refresh path.
    v_text := public.kickoff_build_message(p_agency_id, v_today);

    -- The kickoff takes down the prior EOD message.
    PERFORM public.team_checkin_delete_message(
      p_agency_id, v_chat_id, 'eod', 'reminder', NULL, v_today);
  END IF;

  -- Morning sends the composed text; the marker version is what gets stored.
  IF v_checkin_type = 'morning' THEN
    v_send_text := public.kickoff_compose_message(p_agency_id, v_today, v_text);
  ELSE
    v_send_text := v_text;
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_send_text, v_parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id,
    reminder_text, expected_count
  ) VALUES (p_agency_id, v_today, v_checkin_type, now(), v_message_id, v_text, v_expected)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        expected_count = COALESCE(EXCLUDED.expected_count, public.team_checkin_runs.expected_count),
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s sent%s (msg_id=%s, dow=%s, pending_votes=%s)',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_message_id, v_dow, v_pending_votes));
END;
$function$;
