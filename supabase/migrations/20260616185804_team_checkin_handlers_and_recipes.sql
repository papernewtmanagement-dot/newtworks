-- ============================================================
-- TEAM CHECKIN AUTOMATION HANDLERS
-- 3 internal_handler functions + 9 automation_recipes rows.
-- Recipes stay is_active=false until inbound webhook is built and team is in group.
--
-- DST handling: each cron fires at TWO UTC hours (CDT and CST equivalents).
-- The handler reads input_config.local_time and skips the wrong-DST fire.
-- This makes the whole pipeline DST-self-correcting with no manual intervention.
-- ============================================================

-- 1. HELPER: send a Telegram message via the telegram edge function.
-- Returns the full JSON response from Telegram (so callers can extract message_id).
CREATE OR REPLACE FUNCTION public.telegram_send_message(
  p_chat_id bigint,
  p_text text,
  p_parse_mode text DEFAULT NULL,
  p_reply_to_message_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_payload jsonb;
  v_response jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'action', 'sendMessage',
    'chat_id', p_chat_id,
    'text', p_text
  );
  IF p_parse_mode IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode);
  END IF;
  IF p_reply_to_message_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id);
  END IF;

  SELECT (extensions.http_post(
    'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/telegram',
    v_payload::text,
    'application/json'
  )).content::jsonb INTO v_response;

  RETURN v_response;
END;
$$;

COMMENT ON FUNCTION public.telegram_send_message IS
  'Wrapper around the telegram edge function. Returns the raw Telegram API response.';

-- 2. HELPER: check if current Central time is within tolerance of an intended local_time.
-- Used by all 3 internal handlers to short-circuit when the wrong DST cron fires.
CREATE OR REPLACE FUNCTION public.team_checkin_is_right_local_time(
  p_intended_local_time text,  -- 'HH24:MI' format, e.g. '08:25'
  p_tolerance_minutes int DEFAULT 3
) RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_now_ct timestamp;
  v_intended timestamp;
  v_diff_seconds numeric;
BEGIN
  v_now_ct := (now() AT TIME ZONE 'America/Chicago')::timestamp;
  v_intended := date_trunc('day', v_now_ct) + p_intended_local_time::time;
  v_diff_seconds := abs(extract(epoch FROM (v_now_ct - v_intended)));
  RETURN v_diff_seconds <= p_tolerance_minutes * 60;
END;
$$;

-- 3. HANDLER: send a reminder (T+0).
CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
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
  -- Read recipe input_config
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type in input_config: %', v_checkin_type;
  END IF;

  -- DST self-correction: skip if not right local time
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
    RAISE EXCEPTION 'telegram_team_group_chat_id not set for agency %', p_agency_id;
  END IF;

  -- Build message
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
$$;

-- 4. HANDLER: tag missing respondents (T+5).
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
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
      AND t.category = 'agency'
      AND t.role != 'Owner'
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
$$;

-- 5. HANDLER: compile results and post summary (T+15).
CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
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
  v_responder_count int := 0;
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
  FROM public.team
  WHERE agency_id = p_agency_id
    AND archived_at IS NULL
    AND category = 'agency'
    AND role != 'Owner';

  -- Header
  v_text := '📊 ' || initcap(v_checkin_type) || ' Checkin Results' || E'\n\n';

  -- Per-person breakdown
  FOR v_row IN
    SELECT
      t.first_name,
      tc.quotes_week,
      tc.sales_points_quarter,
      tc.is_proxy_submission,
      submitted_by.first_name AS submitted_by_first_name
    FROM public.team t
    LEFT JOIN public.team_checkins tc
      ON tc.team_id = t.id
      AND tc.agency_id = t.agency_id
      AND tc.checkin_date = v_today
      AND tc.checkin_type = v_checkin_type
    LEFT JOIN public.team submitted_by
      ON submitted_by.id = tc.submitted_by_team_id
    WHERE t.agency_id = p_agency_id
      AND t.archived_at IS NULL
      AND t.category = 'agency'
      AND t.role != 'Owner'
    ORDER BY t.first_name
  LOOP
    IF v_row.quotes_week IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.first_name || ': '
        || v_row.quotes_week::text || '/' || COALESCE(v_row.sales_points_quarter, 0)::text;
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_total_quotes := v_total_quotes + COALESCE(v_row.quotes_week, 0);
      v_total_sales := v_total_sales + COALESCE(v_row.sales_points_quarter, 0);
      v_responder_count := v_responder_count + 1;
    ELSE
      v_text := v_text || '• ' || v_row.first_name || ': no response' || E'\n';
    END IF;
  END LOOP;

  v_text := v_text || E'\n━━━━━━━━━━━━━━━━━━━\n';
  v_text := v_text || 'TEAM TOTAL: ' || v_total_quotes::text || '/' || v_total_sales::text || E'\n';
  v_text := v_text || '(' || v_responder_count || ' of ' || v_expected_count || ' responded)';

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
      responders_count = v_responder_count,
      expected_count = v_expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_responder_count,
    'output_summary', format('%s compile: %s/%s, totals %s/%s',
      v_checkin_type, v_responder_count, v_expected_count, v_total_quotes, v_total_sales)
  );
END;
$$;

-- 6. INSERT 9 RECIPES (inactive). DST-safe cron: each fires at both CDT and CST UTC hours;
--    handler verifies local_time and skips the wrong fire.
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, input_config, is_active)
VALUES
  -- Morning (8:25 / 8:30 / 8:40 CT)
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Morning Reminder',
   'Posts the 8:25 AM CT morning meeting reminder to the PJS Agency Telegram group with yesterday EOD totals.',
   'cron', '25 13,14 * * 1-5',
   'INTERNAL', 'team_checkin_send_reminder',
   '{"checkin_type":"morning","local_time":"08:25"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Morning Tag Missing',
   'At 8:30 AM CT, tags team members who have not yet posted their morning numbers.',
   'cron', '30 13,14 * * 1-5',
   'INTERNAL', 'team_checkin_tag_missing',
   '{"checkin_type":"morning","local_time":"08:30"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Morning Compile',
   'At 8:40 AM CT, compiles morning responses into a per-person breakdown and team total.',
   'cron', '40 13,14 * * 1-5',
   'INTERNAL', 'team_checkin_compile_results',
   '{"checkin_type":"morning","local_time":"08:40"}'::jsonb, false),

  -- Midday (12:00 / 12:05 / 12:15 CT)
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Midday Reminder',
   'Posts the 12:00 PM CT midday checkin reminder to the PJS Agency Telegram group.',
   'cron', '0 17,18 * * 1-5',
   'INTERNAL', 'team_checkin_send_reminder',
   '{"checkin_type":"midday","local_time":"12:00"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Midday Tag Missing',
   'At 12:05 PM CT, tags team members who have not yet posted their midday numbers.',
   'cron', '5 17,18 * * 1-5',
   'INTERNAL', 'team_checkin_tag_missing',
   '{"checkin_type":"midday","local_time":"12:05"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — Midday Compile',
   'At 12:15 PM CT, compiles midday responses into a per-person breakdown and team total.',
   'cron', '15 17,18 * * 1-5',
   'INTERNAL', 'team_checkin_compile_results',
   '{"checkin_type":"midday","local_time":"12:15"}'::jsonb, false),

  -- EOD (5:00 / 5:05 / 5:15 CT)
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — EOD Reminder',
   'Posts the 5:00 PM CT end-of-day checkin reminder to the PJS Agency Telegram group.',
   'cron', '0 22,23 * * 1-5',
   'INTERNAL', 'team_checkin_send_reminder',
   '{"checkin_type":"eod","local_time":"17:00"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — EOD Tag Missing',
   'At 5:05 PM CT, tags team members who have not yet posted their EOD numbers.',
   'cron', '5 22,23 * * 1-5',
   'INTERNAL', 'team_checkin_tag_missing',
   '{"checkin_type":"eod","local_time":"17:05"}'::jsonb, false),
  ('126794dd-25ff-47d2-a436-724499733365',
   'Team Checkin — EOD Compile',
   'At 5:15 PM CT, compiles EOD responses; the totals feed the NEXT morning reminder.',
   'cron', '15 22,23 * * 1-5',
   'INTERNAL', 'team_checkin_compile_results',
   '{"checkin_type":"eod","local_time":"17:15"}'::jsonb, false);
