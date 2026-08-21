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
  v_total_hits int := 0;
  v_total_target int := 0;
  v_at_or_above_target int := 0;
  v_responded_count int := 0;
  v_expected_count int := 0;
  v_line text;
  v_progress_bar text;
  v_dow int;             -- 0=Sun .. 6=Sat
  v_is_saturday boolean;
  v_header text;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  -- Week starts Sunday per agency convention (NOT ISO Monday)
  v_dow := extract(dow FROM v_today)::int;  -- 0=Sun .. 6=Sat
  v_week_start := (v_today - (v_dow || ' days')::interval)::date;
  v_is_saturday := (v_dow = 6);

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

  IF v_is_saturday THEN
    v_header := E'🏁 Final Health Update — Week of ' || to_char(v_week_start, 'Mon DD') || E'\n(Week wraps tonight)\n\n';
  ELSE
    v_header := E'💪 Health Goal Update — Week of ' || to_char(v_week_start, 'Mon DD') || E'\n\n';
  END IF;
  v_text := v_header;

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
    week_data AS (
      SELECT thc.team_id, thc.log_date, thc.hit_today, thc.week_total_override, thc.submitted_at
      FROM public.team_health_checkins thc
      WHERE thc.agency_id = p_agency_id
        AND thc.log_date >= v_week_start
        AND thc.log_date <= v_today
    ),
    latest_override AS (
      SELECT DISTINCT ON (team_id)
        team_id, log_date AS override_date, week_total_override
      FROM week_data
      WHERE week_total_override IS NOT NULL
      ORDER BY team_id, log_date DESC, submitted_at DESC
    ),
    yes_count_after_override AS (
      SELECT wd.team_id, COUNT(*) AS cnt
      FROM week_data wd
      LEFT JOIN latest_override lo ON lo.team_id = wd.team_id
      WHERE wd.hit_today = true
        AND (lo.override_date IS NULL OR wd.log_date > lo.override_date)
      GROUP BY wd.team_id
    ),
    days_responded AS (
      SELECT team_id, COUNT(DISTINCT log_date) AS days FROM week_data GROUP BY team_id
    )
    SELECT
      e.first_name,
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
      IF i <= v_row.hits THEN
        v_progress_bar := v_progress_bar || '🟩';
      ELSE
        v_progress_bar := v_progress_bar || '⬜';
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

    v_total_hits := v_total_hits + v_row.hits;
    v_total_target := v_total_target + v_target;
    IF v_row.days_responded > 0 THEN
      v_responded_count := v_responded_count + 1;
    END IF;
  END LOOP;

  v_text := v_text || E'\n━━━━━━━━━━━━━━━━━━━\n';
  v_text := v_text || 'TEAM: ' || v_total_hits || '/' || v_total_target || ' total workouts';
  v_text := v_text || ' • ' || v_at_or_above_target || '/' || v_expected_count || ' at goal';
  v_text := v_text || E'\n(' || v_responded_count || ' of ' || v_expected_count || ' reporting)';

  -- Closing line by day-of-week
  IF v_at_or_above_target = v_expected_count AND v_expected_count > 0 THEN
    IF v_is_saturday THEN
      v_text := v_text || E'\n\n🔥 Whole team finished at goal. That''s how a week closes.';
    ELSE
      v_text := v_text || E'\n\n🔥 Whole team at goal. That''s what showing up looks like.';
    END IF;
  ELSIF v_is_saturday THEN
    v_text := v_text || E'\n\nWeek''s in the books. Fresh slate tomorrow.';
  ELSIF v_dow = 5 THEN
    -- Friday: one day left in the week (Saturday)
    v_text := v_text || E'\n\nOne day left this week — Saturday close coming.';
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
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = 'health_eve';

  RETURN jsonb_build_object(
    'records_processed', v_responded_count,
    'output_summary', format('health_eve compile (dow=%s): %s/%s reporting, %s at goal, %s total workouts',
      v_dow, v_responded_count, v_expected_count, v_at_or_above_target, v_total_hits)
  );
END;
$function$;
