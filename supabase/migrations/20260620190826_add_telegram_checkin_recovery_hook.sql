-- =========================================================================
-- Telegram checkin recovery hook
--
-- Adds telegram_recover_checkins(date, text) which posts to the telegram
-- edge function's "recoverCheckins" action. The edge function scans the
-- chatter log (public.telegram_group_messages) for the given day and writes
-- team_checkins / team_health_checkins rows for any messages that flew under
-- the live parser.
--
-- The three plpgsql recipes that read the checkin tables are then patched
-- to call recovery FIRST so they see the recovered rows.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.telegram_recover_checkins(
  p_checkin_date date,
  p_checkin_type text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'extensions'
AS $func$
DECLARE
  v_response jsonb;
BEGIN
  v_response := (extensions.http_post(
    'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/telegram',
    json_build_object(
      'action', 'recoverCheckins',
      'checkin_date', p_checkin_date::text,
      'checkin_type', p_checkin_type
    )::text,
    'application/json'
  )).content::jsonb;
  RETURN v_response;
EXCEPTION WHEN OTHERS THEN
  -- Recovery is best-effort. Never propagate an exception to the caller;
  -- the upstream recipe must still run even if recovery fails.
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$func$;

COMMENT ON FUNCTION public.telegram_recover_checkins(date, text) IS
  'Best-effort recovery pass: posts to the telegram edge function''s recoverCheckins action which scans telegram_group_messages for the given day and writes any missed team_checkins / team_health_checkins rows. Idempotent. Called from team_checkin_tag_missing, team_checkin_compile_results, and team_health_checkin_compile before they read the source tables.';


-- =========================================================================
-- team_checkin_tag_missing  (work checkins: midday, EOD, morning-if-active)
-- Recovery call added immediately after v_today is computed.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_missing record;
  v_missing_tags text := '';
  v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  -- v14: recovery pass over the chatter log. Best-effort; safe to ignore result.
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  FOR v_missing IN
    SELECT
      t.id,
      t.first_name,
      tmap.telegram_username,
      tmap.telegram_user_id
    FROM public.team t
    LEFT JOIN public.team_telegram_map tmap
      ON tmap.team_id = t.id AND tmap.agency_id = t.agency_id
    LEFT JOIN public.team_checkins tc
      ON tc.team_id = t.id
      AND tc.agency_id = t.agency_id
      AND tc.checkin_date = v_today
      AND tc.checkin_type = v_checkin_type
    WHERE t.agency_id = p_agency_id
      AND t.archived_at IS NULL
      AND t.is_test_user IS NOT TRUE
      AND (
        t.include_in_team_checkins = true OR
        (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')
      )
      AND COALESCE(t.tag_in_team_reminders, true) = true
      AND tc.id IS NULL
    ORDER BY t.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    IF v_missing.telegram_username IS NOT NULL THEN
      v_missing_tags := v_missing_tags || '@' || v_missing.telegram_username || ' ';
    ELSE
      v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
    END IF;
  END LOOP;

  -- Silent path: if everyone has already checked in (or was recovered), do NOT
  -- send a message and do NOT update tag_missing_* fields on the run row.
  IF v_missing_count = 0 THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('%s tag-missing: silent (everyone already in)', v_checkin_type)
    );
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(),
      tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_missing_count,
    'output_summary', format('%s tag-missing: %s pending', v_checkin_type, v_missing_count)
  );
END;
$function$;


-- =========================================================================
-- team_checkin_compile_results  (midday + EOD work compile)
-- Recovery call added immediately after v_today is computed, before the
-- main FOR-loop that reads team_checkins.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_row record;
  v_total_quotes numeric := 0;
  v_total_sales numeric := 0;
  v_fresh_count int := 0;
  v_carried_count int := 0;
  v_no_data_count int := 0;
  v_expected_count int := 0;
  v_type_label text;
  v_wtw record;
  v_q_short int;
  v_sp_short numeric;
  v_q_pass boolean;
  v_sp_pass boolean;
  v_encouragement text;
  v_cpr_id uuid;
  v_pool_both_clear text[] := ARRAY[
    'Both conditions clear. That''s a Win the Week if it holds.',
    'Team''s running its own pace — quotes and SP both ahead. Keep stacking.',
    'On track on both. Don''t let the foot off the gas.'
  ];
  v_pool_quotes_pass_sp_behind text[] := ARRAY[
    'Quotes are flowing — now turn them into closes. The conversation''s happening, the conversion''s the gap.',
    'Activity strong, conversion needs love. Focus the close work.',
    'Plenty of at-bats. Time to drive a few in.'
  ];
  v_pool_sp_pass_quotes_behind text[] := ARRAY[
    'Closes are landing without the activity volume — efficient, but the pipeline thins fast. Feed it with quotes.',
    'SP looks great. Light quotes mean a leaner next week — push the conversations.',
    'Hitting on quality. Now widen the funnel before next week notices.'
  ];
  v_pool_both_behind text[] := ARRAY[
    'Real ground to make up on both. The week''s not done — push the rest hard.',
    'Behind on both. Today and tomorrow are where the week gets won.',
    'Both conditions still open. One conversation can start a streak.'
  ];
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  -- v14: recovery pass over the chatter log. Best-effort; safe to ignore result.
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT count(*) INTO v_expected_count FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
    AND (t.include_in_team_checkins = true OR
         (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'));

  v_type_label := CASE v_checkin_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_checkin_type) END;
  v_text := '📊 ' || v_type_label || ' Checkin Results' || E'\n\n';

  FOR v_row IN
    WITH expected AS (
      SELECT t.id AS team_id, t.first_name FROM public.team t
      WHERE t.agency_id = p_agency_id AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
        AND (t.include_in_team_checkins = true OR
             (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
    ),
    current_period AS (
      SELECT tc.team_id, tc.quotes_week, tc.sales_points_quarter, tc.is_proxy_submission,
             sub.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team sub ON sub.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id AND tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id) tc.team_id, tc.quotes_week, tc.sales_points_quarter,
        tc.checkin_date AS last_date, tc.checkin_type AS last_type
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type)
      ORDER BY tc.team_id, tc.received_at DESC
    )
    SELECT e.team_id, e.first_name,
      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,
      COALESCE(cp.is_proxy_submission, false) AS is_proxy_submission,
      cp.submitted_by_first_name,
      c.quotes_week AS carry_quotes, c.sales_points_quarter AS carry_sales,
      c.last_date, c.last_type
    FROM expected e
    LEFT JOIN current_period cp ON cp.team_id = e.team_id
    LEFT JOIN carried c ON c.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_row.cur_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.first_name || ': '
        || v_row.cur_quotes::text || '/' || to_char(COALESCE(v_row.cur_sales, 0), 'FM999G999G999');
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_total_quotes := v_total_quotes + COALESCE(v_row.cur_quotes, 0);
      v_total_sales := v_total_sales + COALESCE(v_row.cur_sales, 0);
      v_fresh_count := v_fresh_count + 1;
    ELSIF v_row.carry_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.first_name || ': '
        || v_row.carry_quotes::text || '/' || to_char(COALESCE(v_row.carry_sales, 0), 'FM999G999G999')
        || ' (carried from ' || to_char(v_row.last_date, 'Mon DD')
        || ' ' || v_row.last_type || ')' || E'\n';
      v_total_quotes := v_total_quotes + COALESCE(v_row.carry_quotes, 0);
      v_total_sales := v_total_sales + COALESCE(v_row.carry_sales, 0);
      v_carried_count := v_carried_count + 1;
    ELSE
      v_text := v_text || '• ' || v_row.first_name || ': 0/0' || E'\n';
      v_no_data_count := v_no_data_count + 1;
    END IF;
  END LOOP;

  v_text := v_text || E'\nTeam: ' || v_total_quotes::text || '/' || to_char(v_total_sales, 'FM999G999G999');
  v_text := v_text || '  •  ' || v_fresh_count || ' of ' || v_expected_count || ' reporting';

  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, v_today);
  v_q_pass := v_total_quotes >= v_wtw.quotes_target_total;
  v_sp_pass := v_total_sales >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_total_quotes::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_total_sales);

  v_text := v_text || E'\n\n📈 Win the Week — Week ' || v_wtw.week_of_cycle
    || ' of 13 (ends ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E')\n';
  v_text := v_text || '  Quotes: ' || v_total_quotes::text || ' of ' || v_wtw.quotes_target_total::text;
  IF v_q_pass THEN v_text := v_text || '  ✅ cleared';
  ELSE v_text := v_text || '  —  ' || v_q_short::text || ' to clear';
  END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (carryover: ' || v_wtw.quotes_carryover::text || ' from prior week)';
  END IF;
  v_text := v_text || E'\n';
  v_text := v_text || '  SP pace: ' || to_char(v_total_sales, 'FM999G999G999')
    || ' of ' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_sp_pass THEN v_text := v_text || '  ✅ cleared';
  ELSE v_text := v_text || '  —  ' || to_char(v_sp_short, 'FM999G999G999') || ' to clear';
  END IF;
  v_text := v_text || E'\n';

  IF v_q_pass AND v_sp_pass THEN
    v_encouragement := v_pool_both_clear[1 + floor(random() * array_length(v_pool_both_clear, 1))::int];
  ELSIF v_q_pass AND NOT v_sp_pass THEN
    v_encouragement := v_pool_quotes_pass_sp_behind[1 + floor(random() * array_length(v_pool_quotes_pass_sp_behind, 1))::int];
  ELSIF v_sp_pass AND NOT v_q_pass THEN
    v_encouragement := v_pool_sp_pass_quotes_behind[1 + floor(random() * array_length(v_pool_sp_pass_quotes_behind, 1))::int];
  ELSE
    v_encouragement := v_pool_both_behind[1 + floor(random() * array_length(v_pool_both_behind, 1))::int];
  END IF;
  v_text := v_text || E'\n' || v_encouragement;

  v_cpr_id := public.weekly_cpr_upsert_in_progress(p_agency_id, v_today, v_total_quotes, v_total_sales);

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_fresh_count,
      expected_count = v_expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_fresh_count + v_carried_count,
    'output_summary', format('%s compile: %s/%s reporting; team %s/%s; WtW Q:%s/%s SP:%s/%s; cpr_id=%s',
      v_checkin_type, v_fresh_count, v_expected_count, v_total_quotes, v_total_sales,
      v_total_quotes, v_wtw.quotes_target_total, v_total_sales, v_wtw.sp_target, v_cpr_id)
  );
END;
$function$;


-- =========================================================================
-- team_health_checkin_compile  (Mon-Fri evening compile, Saturday compile)
-- Recovery call added immediately after v_today is computed.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.team_health_checkin_compile(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_week_start date;
  v_target int := 5;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_row record;
  v_at_or_above_target int := 0;
  v_on_pace int := 0;
  v_on_time_threshold int;
  v_responded_count int := 0;
  v_expected_count int := 0;
  v_line text;
  v_progress_bar text;
  v_dow int;
  v_is_saturday boolean;
  v_header text;
  v_encouragement_pool text[] := ARRAY[
    'To everyone short of five — the goal is a goal, not a verdict. You showed up, that counts.',
    'Didn''t quite stack five? Even Rocky had off weeks. The training montage continues.',
    'Whoever came up short — five workouts is a tall order, and showing up at all is half the battle.',
    'For the ones who didn''t get there — the couch is undefeated this round, but it doesn''t get the last word.',
    'Off weeks happen to everyone. The work you did still counts.',
    'Didn''t hit five? The streak is just a number — what matters is the next rep.',
    'Anyone short of goal: gravity''s been winning since forever. You got a few back this week. Take the win.',
    'Five''s a stretch goal, not a baseline. Anything north of zero is a deposit in the bank.'
  ];
  v_encouragement text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;
  v_week_start := (v_today - (v_dow || ' days')::interval)::date;
  v_is_saturday := (v_dow = 6);
  v_on_time_threshold := GREATEST(0, v_dow - 1);

  -- v14: recovery pass over the chatter log. Best-effort; safe to ignore result.
  PERFORM public.telegram_recover_checkins(v_today, 'health_eve');

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT count(*) INTO v_expected_count FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
    AND (t.include_in_health_checkins = true OR
         (t.include_in_health_checkins IS NULL AND t.category = 'agency'));

  IF v_is_saturday THEN
    v_header := E'🏁 Final Health Update — Week of ' || to_char(v_week_start, 'Mon DD') || E'\n(Week wraps tonight)\n\n';
  ELSE
    v_header := E'💪 Health Goal Update — Week of ' || to_char(v_week_start, 'Mon DD') || E'\n\n';
  END IF;
  v_text := v_header;

  FOR v_row IN
    WITH expected AS (
      SELECT t.id AS team_id, t.first_name FROM public.team t
      WHERE t.agency_id = p_agency_id AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
        AND (t.include_in_health_checkins = true OR
             (t.include_in_health_checkins IS NULL AND t.category = 'agency'))
    ),
    week_data AS (
      SELECT thc.team_id, thc.log_date, thc.hit_today, thc.week_total_override, thc.submitted_at
      FROM public.team_health_checkins thc
      WHERE thc.agency_id = p_agency_id AND thc.log_date >= v_week_start AND thc.log_date <= v_today
    ),
    latest_override AS (
      SELECT DISTINCT ON (team_id) team_id, log_date AS override_date, week_total_override
      FROM week_data WHERE week_total_override IS NOT NULL
      ORDER BY team_id, log_date DESC, submitted_at DESC
    ),
    yes_count_after_override AS (
      SELECT wd.team_id, COUNT(*) AS cnt
      FROM week_data wd LEFT JOIN latest_override lo ON lo.team_id = wd.team_id
      WHERE wd.hit_today = true AND (lo.override_date IS NULL OR wd.log_date > lo.override_date)
      GROUP BY wd.team_id
    ),
    days_responded AS (
      SELECT team_id, COUNT(DISTINCT log_date) AS days FROM week_data GROUP BY team_id
    )
    SELECT e.first_name,
      COALESCE(lo.week_total_override, 0) + COALESCE(yc.cnt, 0) AS hits,
      COALESCE(dr.days, 0) AS days_responded
    FROM expected e
    LEFT JOIN latest_override lo ON lo.team_id = e.team_id
    LEFT JOIN yes_count_after_override yc ON yc.team_id = e.team_id
    LEFT JOIN days_responded dr ON dr.team_id = e.team_id
    ORDER BY hits DESC NULLS LAST, e.first_name
  LOOP
    v_progress_bar := '';
    FOR i IN 1..v_target LOOP
      IF i <= v_row.hits THEN v_progress_bar := v_progress_bar || '🟩';
      ELSE v_progress_bar := v_progress_bar || '⬜';
      END IF;
    END LOOP;

    IF v_row.hits >= v_target THEN
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  🎉 goal hit — keep stacking';
      v_at_or_above_target := v_at_or_above_target + 1;
    ELSIF v_row.hits = v_target - 1 AND v_dow >= 5 THEN
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  one more workout';
    ELSIF v_row.hits = 0 AND v_is_saturday THEN
      v_line := '• ' || v_row.first_name || ': 0/' || v_target
        || ' ' || v_progress_bar || '  the couch ran the table this week';
    ELSIF v_row.hits = 0 AND v_dow >= 4 THEN
      v_line := '• ' || v_row.first_name || ': 0/' || v_target
        || ' ' || v_progress_bar || '  weekend left to make a dent';
    ELSIF v_row.hits = 0 THEN
      v_line := '• ' || v_row.first_name || ': 0/' || v_target
        || ' ' || v_progress_bar || '  early in the week — plenty of room';
    ELSE
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  keep going';
    END IF;

    v_text := v_text || v_line || E'\n';

    IF v_row.hits >= v_on_time_threshold THEN
      v_on_pace := v_on_pace + 1;
    END IF;
    IF v_row.days_responded > 0 THEN
      v_responded_count := v_responded_count + 1;
    END IF;
  END LOOP;

  IF v_is_saturday THEN
    v_text := v_text || E'\n' || v_at_or_above_target || '/' || v_expected_count || ' hit goal';
  ELSE
    v_text := v_text || E'\n' || v_on_pace || '/' || v_expected_count || ' at goal or on time';
    v_text := v_text || '  •  ' || v_responded_count || ' of ' || v_expected_count || ' reporting';
  END IF;

  IF v_at_or_above_target = v_expected_count AND v_expected_count > 0 THEN
    IF v_is_saturday THEN
      v_text := v_text || E'\n\n🔥 Whole team finished at goal. That''s how a week closes.';
    ELSE
      v_text := v_text || E'\n\n🔥 Whole team at goal. That''s what showing up looks like.';
    END IF;
  ELSIF v_is_saturday THEN
    v_encouragement := v_encouragement_pool[1 + floor(random() * array_length(v_encouragement_pool, 1))::int];
    v_text := v_text || E'\n\n' || v_encouragement;
  ELSIF v_dow = 5 THEN
    v_text := v_text || E'\n\nOne day left this week — Saturday close coming.';
  END IF;

  IF v_is_saturday THEN
    v_text := v_text || E'\n\nWeek''s in the books. Fresh slate tomorrow.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_responded_count,
      expected_count = v_expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = 'health_eve';

  RETURN jsonb_build_object('records_processed', v_responded_count,
    'output_summary', format('health_eve compile (dow=%s, sat=%s): %s/%s hit goal, %s/%s on pace, %s/%s reporting',
      v_dow, v_is_saturday, v_at_or_above_target, v_expected_count,
      v_on_pace, v_expected_count, v_responded_count, v_expected_count));
END;
$function$;
