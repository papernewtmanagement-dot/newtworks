-- Update both compile_results and send_reminder to UPSERT the in-progress
-- weekly_cpr_reports row each time they run.
--
-- compile_results: write with this checkin's totals (always valid current-week data).
-- send_reminder morning path: write with last EOD's totals — but only if that
-- last EOD falls inside the current week. If last EOD is from a prior week
-- (e.g. Monday morning showing prior Friday), this week's quotes_total_net = 0
-- and sp_qtd carries forward from the prior week's value.

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

  -- Write/upsert in-progress weekly_cpr_reports row
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
