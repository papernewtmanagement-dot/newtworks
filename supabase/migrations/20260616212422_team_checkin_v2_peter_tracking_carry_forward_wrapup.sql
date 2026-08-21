-- ============================================================
-- TEAM CHECKIN v2 SCHEMA + LOGIC CHANGES
-- 1. Track Peter's numbers (include in expected) but don't tag him in reminders
-- 2. Carry-forward last known numbers when someone doesn't reply
-- 3. EOD reminder appends "Then begin your daily wrapup" nudge
-- ============================================================

-- ---------- 1. SCHEMA: add include + tag override columns ----------
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS include_in_team_checkins boolean,
  ADD COLUMN IF NOT EXISTS tag_in_team_reminders boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.team.include_in_team_checkins IS
  'NULL = use default rule (category=agency AND role!=Owner). TRUE = force include. FALSE = force exclude.';
COMMENT ON COLUMN public.team.tag_in_team_reminders IS
  'When TRUE, this team member appears in the tag-missing reminder if they have not responded.';

-- Peter: include his numbers, don't tag him
UPDATE public.team
SET include_in_team_checkins = true,
    tag_in_team_reminders = false,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND first_name = 'Peter' AND last_name = 'Story' AND role = 'Owner';

-- ---------- 2. REMINDER: EOD adds wrapup nudge ----------
CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
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
  v_yesterday record;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

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

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'telegram_team_group_chat_id not set';
  END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := E'🌅 Morning meeting in 5 minutes!\n\n';
    SELECT * INTO v_yesterday
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id
      AND checkin_type = 'eod'
      AND checkin_date < v_today
      AND total_quotes_week IS NOT NULL
    ORDER BY checkin_date DESC
    LIMIT 1;

    IF FOUND THEN
      v_text := v_text || format('EOD numbers from %s: team totals were %s/%s%s',
        to_char(v_yesterday.checkin_date, 'Mon DD'),
        COALESCE(v_yesterday.total_quotes_week::text, '0'),
        COALESCE(v_yesterday.total_sales_points_quarter::text, '0'),
        E'\n\n');
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record)\n\n';
    END IF;
  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday checkin!\n\n';
  ELSE
    v_text := E'🌙 EOD checkin!\n\n';
  END IF;

  v_text := v_text
    || E'Reply with your numbers — quotes this week / sales points this quarter:\n'
    || E'   12/45\n\n'
    || E'Covering for someone? Tag their name:\n'
    || E'   Cassandra 5/28';

  -- v2: EOD wrapup nudge
  IF v_checkin_type = 'eod' THEN
    v_text := v_text || E'\n\nThen begin your daily wrapup.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type,
    reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (
    p_agency_id, v_today, v_checkin_type,
    now(), v_message_id, v_text
  )
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s reminder sent (msg_id=%s)', v_checkin_type, v_message_id)
  );
END;
$function$;

-- ---------- 3. TAG-MISSING: respects new include/tag flags ----------
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
      AND COALESCE(t.tag_in_team_reminders, true) = true  -- v2: skip Peter etc.
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

  IF v_missing_count = 0 THEN
    v_text := '✅ All checked in!';
  ELSE
    v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  END IF;

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

-- ---------- 4. COMPILE: carry-forward + Peter included ----------
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

  v_text := '📊 ' || initcap(v_checkin_type) || ' Checkin Results' || E'\n\n';

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
        tc.team_id,
        tc.quotes_week,
        tc.sales_points_quarter,
        tc.is_proxy_submission,
        submitted_by.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team submitted_by ON submitted_by.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = v_today
        AND tc.checkin_type = v_checkin_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id)
        tc.team_id,
        tc.quotes_week,
        tc.sales_points_quarter,
        tc.checkin_date AS last_date,
        tc.checkin_type AS last_type
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type)
      ORDER BY tc.team_id, tc.received_at DESC
    )
    SELECT
      e.first_name,
      cp.quotes_week AS cur_quotes,
      cp.sales_points_quarter AS cur_sales,
      COALESCE(cp.is_proxy_submission, false) AS is_proxy_submission,
      cp.submitted_by_first_name,
      c.quotes_week AS carry_quotes,
      c.sales_points_quarter AS carry_sales,
      c.last_date,
      c.last_type
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
      v_text := v_text || '• ' || v_row.first_name || ': no data yet' || E'\n';
      v_no_data_count := v_no_data_count + 1;
    END IF;
  END LOOP;

  v_text := v_text || E'\n━━━━━━━━━━━━━━━━━━━\n';
  v_text := v_text || 'TEAM TOTAL: ' || v_total_quotes::text || '/' || v_total_sales::text || E'\n';
  v_text := v_text || '(' || v_fresh_count || ' fresh';
  IF v_carried_count > 0 THEN
    v_text := v_text || ', ' || v_carried_count || ' carried';
  END IF;
  IF v_no_data_count > 0 THEN
    v_text := v_text || ', ' || v_no_data_count || ' no data';
  END IF;
  v_text := v_text || ' of ' || v_expected_count || ')';

  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      total_quotes_week = v_total_quotes,
      total_sales_points_quarter = v_total_sales,
      responders_count = v_fresh_count,
      expected_count = v_expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_fresh_count + v_carried_count,
    'output_summary', format('%s compile: %s fresh + %s carried + %s no-data of %s; totals %s/%s',
      v_checkin_type, v_fresh_count, v_carried_count, v_no_data_count, v_expected_count, v_total_quotes, v_total_sales)
  );
END;
$function$;
