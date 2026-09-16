-- Shape (Peter 2026-09-15): unique emoji runs into the Win the Week title, which
-- is now the message title and carries the date. Shared blocks follow: WtW,
-- Stats, Commits. Then whatever is unique to that message, at the end. No block
-- below the title repeats the date any more.

-- Calls header loses the date; the title carries it now.
CREATE OR REPLACE FUNCTION public.render_daily_calls_block(p_agency_id uuid, p_activity_date date)
 RETURNS text LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_out text := ''; v_row record; v_row_count int := 0; v_missed int := 0;
BEGIN
  FOR v_row IN
    SELECT COALESCE(t.nickname, t.first_name) AS display_name,
      dca.inbound_calls_external, dca.outbound_calls_external,
      dca.inbound_talk_time_seconds + dca.outbound_talk_time_seconds AS talk_seconds
    FROM public.daily_call_activity dca
    JOIN public.team t ON t.id = dca.team_member_id
    WHERE dca.agency_id = p_agency_id
      AND dca.activity_date = p_activity_date
      AND dca.team_member_id IS NOT NULL
      AND t.is_admin_backoffice = false
    ORDER BY public.role_level_rank(t.role_level), t.start_date NULLS LAST, t.first_name
  LOOP
    v_row_count := v_row_count + 1;
    v_out := v_out || format(E'• %s: %s/%s/%s min\n',
      v_row.display_name, v_row.inbound_calls_external,
      v_row.outbound_calls_external, v_row.talk_seconds / 60);
  END LOOP;

  IF v_row_count = 0 THEN RETURN ''; END IF;

  SELECT COALESCE(SUM(abandoned_calls_external), 0) + COALESCE(SUM(voicemail_calls_external), 0)
  INTO v_missed
  FROM public.daily_call_activity
  WHERE agency_id = p_agency_id AND activity_date = p_activity_date AND team_member_id IS NULL;

  v_out := E'📞 Calls (in/out/time)\n' || v_out;
  IF v_missed > 0 THEN v_out := v_out || format(E'• Missed: %s\n', v_missed); END IF;

  RETURN rtrim(v_out, E'\n');
END;
$function$;

-- One commits header for all three messages. The kickoff used to pass its own
-- dated header, which is why the same function printed two different titles.
CREATE OR REPLACE FUNCTION public.render_daily_commits_block(p_agency_id uuid, p_date date, p_show_hits boolean DEFAULT false, p_html boolean DEFAULT false, p_header text DEFAULT '🎯 Commits'::text)
 RETURNS text LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_row record; v_text text := ''; v_name text; v_body text; v_mark text;
BEGIN
  FOR v_row IN SELECT * FROM public.daily_commits_for_day(p_agency_id, p_date)
  LOOP
    v_name := v_row.display_name;
    v_body := COALESCE(btrim(v_row.commit_text), '');
    IF p_html THEN
      v_name := replace(replace(replace(v_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_body := replace(replace(replace(v_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    END IF;
    IF v_body = '' THEN
      v_mark := ' ⚠️';
      v_body := 'Missing';
    ELSE
      v_mark := CASE
        WHEN p_show_hits AND v_row.hit IS TRUE THEN ' ✅'
        WHEN p_show_hits AND v_row.hit IS FALSE THEN ' ❌'
        ELSE '' END;
    END IF;
    v_text := v_text || '• ' || v_name || v_mark || ': ' || v_body || E'\n';
  END LOOP;
  IF v_text = '' THEN RETURN NULL; END IF;
  RETURN p_header || E'\n' || rtrim(v_text, E'\n');
END;
$function$;

CREATE OR REPLACE FUNCTION public.kickoff_compose_message(p_agency_id uuid, p_date date, p_stored text)
 RETURNS text LANGUAGE plpgsql STABLE SET search_path TO 'public', 'pg_temp' AS $function$
DECLARE
  v_text text := COALESCE(p_stored, '');
  v_prev date; v_block text;
BEGIN
  IF v_text = '' THEN RETURN NULL; END IF;
  IF position('{{commits}}' IN v_text) = 0 THEN RETURN v_text; END IF;

  -- The kickoff asks people to mark YESTERDAY's commit, the same way the Daily
  -- Kickoff page does. On a Monday that is Friday.
  v_prev := public.checklist_prev_workday(p_agency_id, p_date);
  IF v_prev IS NOT NULL THEN
    v_block := public.render_daily_commits_block(p_agency_id, v_prev, true, false);
  END IF;

  IF v_block IS NULL OR btrim(v_block) = '' THEN
    v_text := replace(v_text, E'\n\n{{commits}}', '');
    v_text := replace(v_text, '{{commits}}', '');
  ELSE
    v_text := replace(v_text, '{{commits}}', v_block);
  END IF;

  RETURN v_text;
END;
$function$;

-- Title line: emoji, cycle week, the week it ends, then the day being reported.
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
    || ', Ends ' || to_char(v_wtw.week_ending_saturday, 'Mon DD')
    || ', ' || to_char(p_as_of_date, 'Mon DD')
    || v_outcome_text || E'\n';

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

-- Stats block is named now that the title carries the date.
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

  v_week_closed := v_display_cycle.week_ending_saturday < v_current_cycle.week_ending_saturday
                   AND EXISTS (SELECT 1 FROM public.weekly_cpr_reports r
                               WHERE r.agency_id = p_agency_id
                                 AND r.week_ending_date = v_display_cycle.week_ending_saturday
                                 AND r.won_the_week IS NOT NULL);

  v_text := '📊 Stats (MP/' || public.lbl_quotes() || '/SP/RP)' || E'\n';

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

  v_emoji := CASE p_kind WHEN 'morning' THEN '☀️' WHEN 'midday' THEN '🕛' ELSE '🌙' END;

  -- The kickoff reports the prior workday. On the first workday of a new week
  -- that is last week, so the title carries won or missed.
  IF v_is_morning THEN
    v_data_date := public.checklist_prev_workday(p_agency_id, p_today);
    v_show_outcome := (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, v_data_date))
                    < (SELECT week_ending_saturday FROM public.current_cycle_info(p_agency_id, p_today));
  ELSE
    v_data_date := p_today;
  END IF;

  -- SHARED: title, stats, commits.
  v_text := public.render_wtw_block(p_agency_id, v_data_date, v_emoji, v_show_outcome);

  SELECT * INTO v_stats FROM public.render_team_stats_block(
    p_agency_id, v_data_date, CASE WHEN v_is_morning THEN 'eod' ELSE p_kind END);
  v_text := v_text || E'\n\n' || v_stats.block_text;

  -- The kickoff marks the prior day's hits and misses, so it stores a marker
  -- that kickoff_compose_message swaps for the live block on every refresh.
  IF v_is_morning THEN
    v_text := v_text || E'\n\n{{commits}}';
  ELSE
    v_commits := public.render_daily_commits_block(p_agency_id, v_data_date, false, v_is_eod);
    IF v_commits IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_commits;
    END IF;
  END IF;

  -- KICKOFF ONLY: calls, then what was missed on yesterday's checklist.
  IF v_is_morning THEN
    v_calls := NULL;
    FOR v_days_back IN 0..4 LOOP
      v_calls := public.render_daily_calls_block(p_agency_id, v_data_date - v_days_back);
      EXIT WHEN v_calls IS NOT NULL AND v_calls <> '';
    END LOOP;
    IF v_calls IS NOT NULL AND v_calls <> '' THEN
      v_text := v_text || E'\n\n' || v_calls;
    END IF;

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
    -- Quote of the day closes the kickoff.
    SELECT quote_text, attribution, video_url INTO v_quote
    FROM public.health_quotes
    WHERE agency_id = p_agency_id AND is_active = true AND pool = 'morning_motivation'
    ORDER BY random() LIMIT 1;
    IF v_quote.quote_text IS NOT NULL THEN
      v_text := v_text || E'\n\n"' || v_quote.quote_text || '"';
      IF v_quote.attribution IS NOT NULL THEN
        v_text := v_text || ' — ' || v_quote.attribution;
      END IF;
      IF v_quote.video_url IS NOT NULL THEN
        v_text := v_text || E'\n▶️ ' || v_quote.video_url;
      END IF;
    END IF;
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
