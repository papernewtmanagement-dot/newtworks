-- All three team messages (kickoff, midday, EOD) are now built by ONE function,
-- public.team_message_build. They differ only in the wrapper: the opening emoji,
-- whether a quote leads, which day's data they read, and what is tacked on the
-- end. Block order for all three: Win the Week, individual stats, calls, commits
-- (Peter 2026-09-15).

-- Telegram auto-links anything shaped like a stock cashtag ($ plus 1-8 capital
-- letters), which is why "$Q" showed up blue and tappable. A zero-width space
-- between the $ and the Q reads identically and is not a cashtag. One function so
-- the label lives in one place.
CREATE OR REPLACE FUNCTION public.lbl_quotes()
 RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT '$' || chr(8203) || 'Q';
$function$;

-- Team sort order everywhere: role level first, tenure inside a role level
-- (Peter 2026-09-15).
CREATE OR REPLACE FUNCTION public.role_level_rank(p_role_level text)
 RETURNS int LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE p_role_level
    WHEN 'Owner'             THEN 1
    WHEN 'Unit Manager'      THEN 2
    WHEN 'Account Manager'   THEN 3
    WHEN 'Account Associate' THEN 4
    WHEN 'Aspirant'          THEN 5
    ELSE 9 END;
$function$;

CREATE OR REPLACE FUNCTION public.render_wtw_block(
  p_agency_id uuid, p_as_of_date date, p_prefix text, p_show_outcome boolean DEFAULT false)
 RETURNS text LANGUAGE plpgsql AS $function$
DECLARE
  v_cycle record; v_wtw record; v_board jsonb;
  v_ttq numeric := 0; v_tts numeric := 0;
  v_outcome record; v_outcome_text text := ''; v_text text;
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_as_of_date);

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_cycle.week_ending_saturday);
  v_ttq := COALESCE((v_board->'team'->>'quotes')::numeric, 0);

  -- Quarter-to-date sales points: the stored column once the week is audited and
  -- frozen, the live helper while the week is still open.
  SELECT COALESCE((
    SELECT r.quarterly_sales_points_qtd FROM public.weekly_cpr_reports r
    WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_cycle.week_ending_saturday
      AND r.won_the_week IS NOT NULL
  ), (
    SELECT COALESCE(SUM(s.sales_points), 0)
    FROM public.get_sales_points_qtd(p_agency_id, v_cycle.week_ending_saturday) s
  ), 0) INTO v_tts;

  IF p_show_outcome THEN
    SELECT won_the_week, COALESCE(quotes_owed_next_week, 0) AS carryover INTO v_outcome
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.week_ending_saturday;
    IF v_outcome.won_the_week IS TRUE  THEN v_outcome_text := ' 🏆 Won'; END IF;
    IF v_outcome.won_the_week IS FALSE THEN v_outcome_text := ' ❌ Missed'; END IF;
    IF v_outcome_text <> '' AND v_outcome.carryover > 0 THEN
      v_outcome_text := v_outcome_text
        || format(' (+%s %s into this week)', v_outcome.carryover, public.lbl_quotes());
    END IF;
  END IF;

  v_text := p_prefix || ' WtW ' || v_wtw.week_of_cycle
    || ', ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || v_outcome_text || E'\n';

  v_text := v_text || '• ' || public.lbl_quotes() || ': '
    || v_ttq::text || '/' || v_wtw.quotes_target_total::text;
  IF v_ttq >= v_wtw.quotes_target_total THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || GREATEST(0, v_wtw.quotes_target_total - v_ttq::int)::text; END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (+' || v_wtw.quotes_carryover::text || ' carryover)';
  END IF;

  v_text := v_text || E'\n• SP: ' || to_char(v_tts, 'FM999G999G999')
    || '/' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_tts >= v_wtw.sp_target THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || to_char(GREATEST(0, v_wtw.sp_target - v_tts), 'FM999G999G999'); END IF;

  RETURN v_text;
END;
$function$;

CREATE OR REPLACE FUNCTION public.render_team_stats_block(
  p_agency_id uuid, p_display_date date, p_fresh_type text)
 RETURNS TABLE(block_text text, expected_count integer)
 LANGUAGE plpgsql AS $function$
DECLARE
  v_today_real date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_display_cycle record; v_current_cycle record;
  v_week_closed boolean; v_board jsonb; v_row record; v_emoji text;
  v_text text; v_expected int := 0;
BEGIN
  SELECT * INTO v_display_cycle FROM public.current_cycle_info(p_agency_id, p_display_date);
  SELECT * INTO v_current_cycle FROM public.current_cycle_info(p_agency_id, v_today_real);

  -- A closed, audited week shows its FINAL numbers from the CPR. A live week
  -- shows the running board.
  v_week_closed := v_display_cycle.week_ending_saturday < v_current_cycle.week_ending_saturday
                   AND EXISTS (SELECT 1 FROM public.weekly_cpr_reports r
                               WHERE r.agency_id = p_agency_id
                                 AND r.week_ending_date = v_display_cycle.week_ending_saturday
                                 AND r.won_the_week IS NOT NULL);

  v_text := '📊 ' || to_char(p_display_date, 'Mon DD')
            || ' (MP/' || public.lbl_quotes() || '/SP/RP)' || E'\n';

  SELECT count(*) INTO v_expected
  FROM public.get_expected_teammates(p_agency_id, 'work_display', p_display_date);

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_display_cycle.week_ending_saturday);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name, start_date, role_level
      FROM public.get_expected_teammates(p_agency_id, 'work_display', p_display_date)
    ),
    board AS (
      SELECT (p->>'team_member_id')::uuid AS team_id,
             COALESCE((p->'quotes'->>'count')::numeric, 0)     AS quotes,
             COALESCE((p->'marketing'->>'points')::numeric, 0) AS marketing,
             COALESCE((p->'retention'->>'net')::numeric, 0)    AS retention
      FROM jsonb_array_elements(v_board->'people') p
    ),
    spq AS (
      SELECT s.team_id, s.sales_points AS sp_qtd,
             GREATEST(0, s.sales_points - COALESCE(pv.sales_points, 0)) AS sp_week
      FROM public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday) s
      LEFT JOIN public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday - 7) pv
        ON pv.team_id = s.team_id
    ),
    cpr AS (
      SELECT d.team_member_id AS team_id, d.quotes_discussed, d.sales_points
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r1 ON r1.id = d.weekly_cpr_report_id
      WHERE r1.agency_id = p_agency_id
        AND r1.week_ending_date = v_display_cycle.week_ending_saturday
    )
    SELECT e.team_id, e.display_name,
      cd.team_id AS cpr_team_id, cd.quotes_discussed AS cpr_quotes, cd.sales_points AS cpr_sales,
      b.team_id AS board_team_id, b.quotes, b.marketing, b.retention,
      COALESCE(sq.sp_qtd, 0) AS sp_qtd, COALESCE(sq.sp_week, 0) AS sp_week
    FROM expected e
    LEFT JOIN board b ON b.team_id = e.team_id
    LEFT JOIN spq sq ON sq.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY public.role_level_rank(e.role_level), e.start_date NULLS LAST, e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(COALESCE(v_row.marketing, 0)), 'FM999G999G999') || '/'
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(floor(COALESCE(v_row.cpr_sales, 0)), 'FM999G999G999') || '/'
        || to_char(floor(COALESCE(v_row.retention, 0)), 'FM999G999G999') || E'\n';
    ELSIF v_row.board_team_id IS NOT NULL THEN
      v_emoji := public.checkin_reaction_emoji(
        p_agency_id, v_row.team_id, v_row.quotes, p_display_date, p_fresh_type, v_row.sp_week);
      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(v_row.marketing), 'FM999G999G999') || '/'
        || v_row.quotes::text || '/'
        || to_char(floor(v_row.sp_qtd), 'FM999G999G999') || '/'
        || to_char(floor(v_row.retention), 'FM999G999G999')
        || COALESCE(' ' || v_emoji, '') || E'\n';
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0/0/0' || E'\n';
    END IF;
  END LOOP;

  RETURN QUERY SELECT rtrim(v_text, E'\n'), v_expected;
END;
$function$;

-- The one builder. p_kind is 'morning', 'midday' or 'eod'.
CREATE OR REPLACE FUNCTION public.team_message_build(
  p_agency_id uuid, p_kind text, p_today date)
 RETURNS TABLE(message_text text, parse_mode text, expected_count integer)
 LANGUAGE plpgsql AS $function$
DECLARE
  v_is_morning boolean := (p_kind = 'morning');
  v_is_eod     boolean := (p_kind = 'eod');
  v_data_date date; v_show_outcome boolean := false;
  v_emoji text; v_text text := ''; v_quote record;
  v_stats record; v_calls text; v_days_back int; v_commits text;
  v_checklist text; v_votes int := 0;
  v_wrapup_url text := 'https://newtworks.vercel.app/?tab=checklist';
BEGIN
  IF p_kind NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'team_message_build: unsupported kind %', p_kind;
  END IF;

  v_emoji := CASE p_kind WHEN 'morning' THEN '🌅' WHEN 'midday' THEN '☀️' ELSE '🌙' END;

  -- The kickoff reports the prior workday. On the first workday of a new week
  -- that is last week, so the Win the Week line carries won or missed.
  IF v_is_morning THEN
    v_data_date := public.checklist_prev_workday(p_agency_id, p_today);
    v_show_outcome := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, v_data_date))
                    < (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, p_today));
  ELSE
    v_data_date := p_today;
  END IF;

  -- Wrapper, part one. The kickoff leads with the quote; the other two run the
  -- emoji straight into the Win the Week title.
  IF v_is_morning THEN
    v_text := v_emoji || ' ';
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
    END IF;
    v_text := v_text || E'\n\n' || public.render_wtw_block(p_agency_id, v_data_date, '📈', v_show_outcome);
  ELSE
    v_text := public.render_wtw_block(p_agency_id, v_data_date, v_emoji, false);
  END IF;

  -- Individual stats.
  SELECT * INTO v_stats FROM public.render_team_stats_block(
    p_agency_id, v_data_date, CASE WHEN v_is_morning THEN 'eod' ELSE p_kind END);
  v_text := v_text || E'\n\n' || v_stats.block_text;

  -- Calls. Newest day with data, starting at the reported day.
  v_calls := NULL;
  FOR v_days_back IN 0..4 LOOP
    v_calls := public.render_daily_calls_block(p_agency_id, v_data_date - v_days_back);
    EXIT WHEN v_calls IS NOT NULL AND v_calls <> '';
  END LOOP;
  IF v_calls IS NOT NULL AND v_calls <> '' THEN
    v_text := v_text || E'\n\n' || v_calls;
  END IF;

  -- Commits. The kickoff marks the prior day's hits and misses, so it stores a
  -- marker that kickoff_compose_message swaps for the live block on every refresh.
  IF v_is_morning THEN
    v_text := v_text || E'\n\n{{commits}}';
  ELSE
    v_commits := public.render_daily_commits_block(p_agency_id, v_data_date, false, v_is_eod);
    IF v_commits IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_commits;
    END IF;
  END IF;

  -- Kickoff closes on what was missed on the checklist the day before.
  IF v_is_morning THEN
    v_checklist := public.render_daily_checklist_bridge(p_agency_id, p_today);
    IF v_checklist IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_checklist;
    END IF;
  END IF;

  IF v_is_eod THEN
    v_text := v_text || E'\n\n📝 <a href="' || v_wrapup_url || E'">Don''t forget wrap-up</a>';
  END IF;

  SELECT COUNT(*) INTO v_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > now();
  IF v_votes = 1 THEN v_text := v_text || E'\n\n🗳️ Vote Required';
  ELSIF v_votes > 1 THEN v_text := v_text || E'\n\n🗳️ Vote Required (' || v_votes::text || ')';
  END IF;

  IF v_is_morning THEN
    v_text := v_text || E'\n\n🏃 Remember health! Check in at 7 pm.';
  ELSE
    -- The nag at +20 reads team_checkin_acks, so the acknowledgment line has to
    -- be here. One copy of the wording lives in team_checkin_reminder_ack_line().
    v_text := v_text || E'\n\n' || public.team_checkin_reminder_ack_line();
  END IF;

  RETURN QUERY SELECT v_text,
    CASE WHEN v_is_eod THEN 'HTML' ELSE NULL END::text,
    v_stats.expected_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_dow int; v_text text; v_response jsonb; v_message_id bigint;
  v_is_recovery boolean := false; v_built record; v_send_text text;
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

  -- Kept from the old compile step so the in-progress CPR row still gets made.
  IF v_checkin_type IN ('midday', 'eod') THEN
    PERFORM public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);
  END IF;

  SELECT * INTO v_built FROM public.team_message_build(p_agency_id, v_checkin_type, v_today);
  v_text := v_built.message_text;

  -- The EOD message replaces the midday one; the kickoff takes down the prior EOD.
  IF v_checkin_type = 'eod' THEN
    PERFORM public.team_checkin_delete_message(p_agency_id, v_chat_id, 'midday', 'reminder', v_today);
  ELSIF v_checkin_type = 'morning' THEN
    PERFORM public.team_checkin_delete_message(p_agency_id, v_chat_id, 'eod', 'reminder', NULL, v_today);
  END IF;

  -- Morning sends the composed text; the marker version is what gets stored.
  IF v_checkin_type = 'morning' THEN
    v_send_text := public.kickoff_compose_message(p_agency_id, v_today, v_text);
  ELSE
    v_send_text := v_text;
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_send_text, v_built.parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type, reminder_sent_at, reminder_message_id,
    reminder_text, expected_count
  ) VALUES (p_agency_id, v_today, v_checkin_type, now(), v_message_id, v_text, v_built.expected_count)
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        expected_count = COALESCE(EXCLUDED.expected_count, public.team_checkin_runs.expected_count),
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s sent%s (msg_id=%s, dow=%s)',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_message_id, v_dow));
END;
$function$;

DROP FUNCTION IF EXISTS public.kickoff_build_message(uuid, date);
DROP FUNCTION IF EXISTS public.team_checkin_build_results_message(uuid, text, date);
DROP FUNCTION IF EXISTS public.render_team_status_block(uuid, date, text, text, date);
