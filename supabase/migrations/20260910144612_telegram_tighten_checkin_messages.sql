-- Peter directive 2026-09-10: tighten the team channel.
--  * Blank lines BETWEEN sections stay. Per-person lines stay on their own lines.
--  * The blank line directly under a section header goes.
--  * "Kickoff in 5!" header removed - the morning message opens on the quote.
--  * Horizontal divider bars removed, replaced by a single blank line.
--  * Standing instruction lines removed from midday / EOD / health prompts.
--  * Friday wrapup points at the Daily Wrap-up page instead of restating six items.
--  * Deposit-record reminder STAYS daily (Peter: it is there so they record the
--    deposit if they have not already).

-- Header no longer carries a trailing blank line before the per-person lines.
CREATE OR REPLACE FUNCTION public.render_team_status_block(p_agency_id uuid, p_as_of_date date, p_fresh_type text, p_header_label text, p_wtw_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(block_text text, encouragement_text text, team_total_quotes numeric, team_total_sales numeric, fresh_count integer, carried_count integer, no_data_count integer, expected_count integer)
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_wtw_date date; v_wtw_cycle record; v_wtw_week_start date;
  v_display_cycle record; v_display_week_start date;
  v_row record; v_text text := ''; v_ttq numeric := 0; v_tts numeric := 0;
  v_fresh int := 0; v_carried int := 0; v_nodata int := 0; v_expected int := 0;
  v_wtw record; v_targets record; v_q_pass boolean; v_sp_pass boolean;
  v_q_short int; v_sp_short numeric; v_encouragement text; v_carry_type_label text;
  v_display_quotes int; v_carry_label text; v_hour_ct int; v_dow int;
  v_intra_day numeric; v_pace numeric; v_this_week_sp_increment numeric;
  v_prior_sp_cumulative numeric; v_q_pace_pass boolean; v_sp_pace_pass boolean;
  v_totals record; v_week_closed boolean;
  v_pool_pre_work text[] := ARRAY[
    'New week open. Set the tone.',
    'Fresh page. Let''s start it right.',
    'First step of the week — make it count.'];
  v_pool_both_at_pace text[] := ARRAY[
    'Both conditions running at pace. Trust the process.',
    'Team''s stacking on both. Keep the tempo.',
    'Ahead on both. Guard the lead.'];
  v_pool_quotes_at_pace_sp_behind text[] := ARRAY[
    'Quote flow''s healthy — now the conversion has to follow. Close work.',
    'Activity strong, SP catching up next. Focus the closes.',
    'Plenty of at-bats. Drive some in.'];
  v_pool_sp_at_pace_quotes_behind text[] := ARRAY[
    'SP running ahead on light quotes — efficient, but feed the pipeline.',
    'Closes landing. Push quote count to protect next week.',
    'Quality''s there. Now widen the funnel.'];
  v_pool_both_behind_pace text[] := ARRAY[
    'Behind pace on both. Focus what''s in front of you — one strong conversation resets the tone.',
    'Ground to make up on both. Steady push.',
    'Both open. Every conversation counts.'];
BEGIN
  v_wtw_date := COALESCE(p_wtw_as_of_date, p_as_of_date);
  SELECT * INTO v_wtw_cycle FROM public.current_cycle_info(p_agency_id, v_wtw_date);
  v_wtw_week_start := v_wtw_cycle.week_ending_saturday - 6;

  SELECT * INTO v_display_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);
  v_display_week_start := v_display_cycle.week_ending_saturday - 6;

  v_week_closed := v_display_cycle.week_ending_saturday < v_wtw_cycle.week_ending_saturday
                   AND EXISTS (
                     SELECT 1 FROM public.weekly_cpr_reports r0
                     WHERE r0.agency_id = p_agency_id
                       AND r0.week_ending_date = v_display_cycle.week_ending_saturday
                       AND r0.won_the_week IS NOT NULL);

  -- Single newline: the blank line under the header was dead space (Peter 2026-09-10).
  v_text := p_header_label || E'\n';

  SELECT count(*) INTO v_expected
  FROM public.get_expected_teammates(p_agency_id, 'work_display', v_wtw_date);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name
      FROM public.get_expected_teammates(p_agency_id, 'work_display', v_wtw_date)
    ),
    current_period AS (
      SELECT tc.team_id, tc.quotes_week, tc.sales_points_quarter, tc.is_proxy_submission,
             sub.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team sub ON sub.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = p_as_of_date
        AND tc.checkin_type = p_fresh_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id)
        tc.team_id, tc.quotes_week, tc.sales_points_quarter,
        tc.checkin_date AS last_date, tc.checkin_type AS last_type,
        (tc.checkin_date < v_display_week_start) AS is_prior_week
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = p_as_of_date AND tc.checkin_type = p_fresh_type)
      ORDER BY tc.team_id, tc.received_at DESC
    ),
    cpr AS (
      SELECT d.team_member_id AS team_id, d.quotes_discussed, d.sales_points
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r1 ON r1.id = d.weekly_cpr_report_id
      WHERE r1.agency_id = p_agency_id
        AND r1.week_ending_date = v_display_cycle.week_ending_saturday
    )
    SELECT e.team_id, e.display_name, e.first_name,
      cd.team_id AS cpr_team_id, cd.quotes_discussed AS cpr_quotes, cd.sales_points AS cpr_sales,
      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,
      COALESCE(cp.is_proxy_submission, false) AS is_proxy_submission,
      cp.submitted_by_first_name,
      c.quotes_week AS carry_quotes, c.sales_points_quarter AS carry_sales,
      c.last_date, c.last_type, c.is_prior_week
    FROM expected e
    LEFT JOIN current_period cp ON cp.team_id = e.team_id
    LEFT JOIN carried c ON c.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(COALESCE(v_row.cpr_sales, 0), 'FM999G999G999') || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.cur_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_row.cur_quotes::text || '/'
        || to_char(COALESCE(v_row.cur_sales, 0), 'FM999G999G999');
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.carry_quotes IS NOT NULL THEN
      v_carry_type_label := CASE v_row.last_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_row.last_type) END;
      IF COALESCE(v_row.is_prior_week, false) THEN
        v_display_quotes := 0;
        v_carry_label := 'SP from ' || v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      ELSE
        v_display_quotes := v_row.carry_quotes;
        v_carry_label := v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      END IF;
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_display_quotes::text || '/'
        || to_char(COALESCE(v_row.carry_sales, 0), 'FM999G999G999')
        || ' (' || v_carry_label || ')' || E'\n';
      v_carried := v_carried + 1;
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0' || E'\n';
      v_nodata := v_nodata + 1;
    END IF;
  END LOOP;

  SELECT * INTO v_totals FROM public.get_team_checkin_totals(p_agency_id, v_wtw_week_start, v_wtw_cycle.week_ending_saturday);
  v_ttq := v_totals.total_quotes;

  SELECT COALESCE((
    SELECT quarterly_sales_points_qtd
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_wtw_cycle.week_ending_saturday
  ), 0) INTO v_tts;

  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, v_wtw_date);
  SELECT * INTO v_targets FROM public.compute_wtw_week_targets(p_agency_id, v_wtw_week_start);
  v_this_week_sp_increment := v_targets.this_week_sp_increment;
  v_prior_sp_cumulative := v_wtw.sp_target - v_this_week_sp_increment;

  v_hour_ct := extract(hour FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_dow := extract(isodow FROM v_wtw_date)::int;
  v_intra_day := CASE WHEN v_hour_ct < 12 THEN 0.0 WHEN v_hour_ct < 16 THEN 0.5 ELSE 1.0 END;
  IF v_dow BETWEEN 1 AND 5 THEN
    v_pace := LEAST(1.0, ((v_dow - 1)::numeric + v_intra_day) / 5.0);
  ELSIF v_dow = 6 THEN v_pace := 1.0;
  ELSE v_pace := 0.0;
  END IF;

  v_q_pass := v_ttq >= v_wtw.quotes_target_total;
  v_sp_pass := v_tts >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_ttq::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_tts);
  v_q_pace_pass := v_ttq >= (v_wtw.quotes_target_total::numeric * v_pace);
  v_sp_pace_pass := v_tts >= (v_prior_sp_cumulative + v_this_week_sp_increment * v_pace);

  -- Blank line BEFORE the section header stays. Blank line AFTER it is gone.
  v_text := v_text || E'\n📈 WtW ' || v_wtw.week_of_cycle
    || ' ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E'\n';
  v_text := v_text || '  Quotes: ' || v_ttq::text || '/' || v_wtw.quotes_target_total::text;
  IF v_q_pass THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || v_q_short::text; END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (+' || v_wtw.quotes_carryover::text || ' carryover)';
  END IF;
  v_text := v_text || E'\n';
  v_text := v_text || '  Sales: ' || to_char(v_tts, 'FM999G999G999')
    || '/' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_sp_pass THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || to_char(v_sp_short, 'FM999G999G999'); END IF;
  v_text := v_text || E'\n';

  IF v_pace <= 0 THEN
    v_encouragement := v_pool_pre_work[1 + floor(random() * array_length(v_pool_pre_work, 1))::int];
  ELSIF v_q_pace_pass AND v_sp_pace_pass THEN
    v_encouragement := v_pool_both_at_pace[1 + floor(random() * array_length(v_pool_both_at_pace, 1))::int];
  ELSIF v_q_pace_pass AND NOT v_sp_pace_pass THEN
    v_encouragement := v_pool_quotes_at_pace_sp_behind[1 + floor(random() * array_length(v_pool_quotes_at_pace_sp_behind, 1))::int];
  ELSIF v_sp_pace_pass AND NOT v_q_pace_pass THEN
    v_encouragement := v_pool_sp_at_pace_quotes_behind[1 + floor(random() * array_length(v_pool_sp_at_pace_quotes_behind, 1))::int];
  ELSE
    v_encouragement := v_pool_both_behind_pace[1 + floor(random() * array_length(v_pool_both_behind_pace, 1))::int];
  END IF;

  RETURN QUERY SELECT v_text, v_encouragement, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$fn$;

-- Calls block header also loses its trailing blank (it never had one) - unchanged,
-- but the reminder now puts a blank line before it, same as every other section.

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
    -- No "Kickoff in 5!" header (Peter 2026-09-10). The quote opens the message.
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
    -- Standing instruction lines removed (Peter 2026-09-10); they live on a
    -- pinned message in the group instead of every reminder.
    v_text := E'☀️ Midday';
  ELSE
    v_text := E'🌙 EOD';
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

  -- Deposit records reminder STAYS on every EOD (Peter 2026-09-10): its job is to
  -- catch a deposit that has not been recorded yet. Divider bar removed only.
  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  -- Friday wrapup block lives on the EOD compile only now - it used to appear on
  -- both the reminder and the compile, thirty minutes apart.

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
  v_reminder_msg_id bigint; v_tag_msg_id bigint; v_edited boolean := false;
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

  -- The compile now REPLACES the reminder message, so anything that was on the
  -- reminder and still needs saying has to be carried across. Deposit records is
  -- the one (Peter 2026-09-10 - it must stay on every EOD).
  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  -- Friday wrapup points at the manual page instead of restating the six items.
  -- The page is authoritative (Peter 2026-08-07) and is now the only copy.
  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n📝 Weekly wrapup — email paper.newt.management@gmail.com. '
      || E'What to include: <a href="' || v_wrapup_url || E'">Daily Wrap-up</a>';
  END IF;

  -- Edit the reminder in place rather than posting a second bubble.
  IF v_reminder_msg_id IS NOT NULL THEN
    v_response := public.telegram_edit_message_text(v_chat_id, v_reminder_msg_id, v_text, v_parse_mode);
    IF (v_response->>'ok')::boolean IS TRUE THEN
      v_edited := true;
      v_message_id := v_reminder_msg_id;
    END IF;
  END IF;

  IF NOT v_edited THEN
    v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
    IF (v_response->>'ok')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
    END IF;
    v_message_id := (v_response->'result'->>'message_id')::bigint;
  END IF;

  -- The tag-missing nudge has done its job once results are posted.
  IF v_tag_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_tag_msg_id);
  END IF;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_block.fresh_count,
      expected_count = v_block.expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_block.fresh_count + v_block.carried_count,
    'output_summary', format('%s compile%s: %s/%s reporting; team %s/%s; %s; cpr_id=%s',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_block.fresh_count, v_block.expected_count,
      v_block.team_total_quotes, v_block.team_total_sales,
      CASE WHEN v_edited THEN 'edited reminder in place' ELSE 'posted new message' END,
      v_cpr_id));
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

  v_text := E'💪 Exercise today? Goal: 5/week.';

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