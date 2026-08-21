-- Stop writing total_quotes_week / total_sales_points_quarter from the EOD compile.
-- All consumers now compute these at runtime from team_checkins (per the
-- compensation_data_freshness principle posture extended to team check-in totals).
-- Columns left in place (existing values are now historical/wrong, do not read).
-- Dropping the columns is the natural follow-up but is destructive, so it's gated.

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

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT count(*) INTO v_expected_count
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.archived_at IS NULL
    AND t.is_test_user IS NOT TRUE
    AND (
      t.include_in_team_checkins = true OR
      (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')
    );

  v_type_label := CASE v_checkin_type
                    WHEN 'eod' THEN 'EOD'
                    ELSE initcap(v_checkin_type)
                  END;

  v_text := '📊 ' || v_type_label || ' Checkin Results' || E'\n\n';

  FOR v_row IN
    WITH expected AS (
      SELECT t.id AS team_id, t.first_name
      FROM public.team t
      WHERE t.agency_id = p_agency_id
        AND t.archived_at IS NULL
        AND t.is_test_user IS NOT TRUE
        AND (
          t.include_in_team_checkins = true OR
          (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')
        )
    ),
    current_period AS (
      SELECT
        tc.team_id, tc.quotes_week, tc.sales_points_quarter, tc.is_proxy_submission,
        submitted_by.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team submitted_by ON submitted_by.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = v_today
        AND tc.checkin_type = v_checkin_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id)
        tc.team_id, tc.quotes_week, tc.sales_points_quarter,
        tc.checkin_date AS last_date, tc.checkin_type AS last_type
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type)
      ORDER BY tc.team_id, tc.received_at DESC
    )
    SELECT
      e.team_id, e.first_name,
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
        || v_row.cur_quotes::text || '/' || COALESCE(v_row.cur_sales, 0)::text;
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_total_quotes := v_total_quotes + COALESCE(v_row.cur_quotes, 0);
      v_total_sales := v_total_sales + COALESCE(v_row.cur_sales, 0);
      v_fresh_count := v_fresh_count + 1;
    ELSIF v_row.carry_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.first_name || ': '
        || v_row.carry_quotes::text || '/' || COALESCE(v_row.carry_sales, 0)::text
        || ' (carried from ' || to_char(v_row.last_date, 'Mon DD')
        || ' ' || v_row.last_type || ')'
        || E'\n';
      v_total_quotes := v_total_quotes + COALESCE(v_row.carry_quotes, 0);
      v_total_sales := v_total_sales + COALESCE(v_row.carry_sales, 0);
      v_carried_count := v_carried_count + 1;
    ELSE
      v_text := v_text || '• ' || v_row.first_name || ': 0/0' || E'\n';
      v_no_data_count := v_no_data_count + 1;
    END IF;
  END LOOP;

  v_text := v_text || E'\nTeam: ' || v_total_quotes::text || '/' || v_total_sales::text;
  v_text := v_text || '  •  ' || v_fresh_count || ' fresh';
  IF v_carried_count > 0 THEN
    v_text := v_text || ', ' || v_carried_count || ' carried';
  END IF;
  IF v_no_data_count > 0 THEN
    v_text := v_text || ', ' || v_no_data_count || ' at 0/0';
  END IF;
  v_text := v_text || ' of ' || v_expected_count;

  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  -- v2: write only compile metadata (timestamp, message id, fresh + expected counts).
  -- NO total_quotes_week / total_sales_points_quarter writes. Totals are runtime-only.
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
    'output_summary', format('%s compile: %s fresh + %s carried + %s zero of %s; totals %s/%s (runtime-only, not stored)',
      v_checkin_type, v_fresh_count, v_carried_count, v_no_data_count, v_expected_count,
      v_total_quotes, v_total_sales)
  );
END;
$function$;

-- Mark the deprecated columns so future readers know not to use them
COMMENT ON COLUMN public.team_checkin_runs.total_quotes_week IS
  'DEPRECATED 2026-06-17. Totals are computed at runtime from team_checkins per the runtime-truth rule. Values in this column are historical/stale; do not read.';
COMMENT ON COLUMN public.team_checkin_runs.total_sales_points_quarter IS
  'DEPRECATED 2026-06-17. Totals are computed at runtime from team_checkins per the runtime-truth rule. Values in this column are historical/stale; do not read.';
