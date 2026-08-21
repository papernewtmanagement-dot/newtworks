-- New function: sends via @paper_newt_bot (the DM bot Peter has /start-ed),
-- not @pjsagencybot (the team group bot).
CREATE OR REPLACE FUNCTION public.paper_newt_send_message(
  p_chat_id bigint,
  p_text text,
  p_parse_mode text DEFAULT NULL,
  p_reply_to_message_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_token       text;
  v_payload     jsonb;
  v_request_id  bigint;
  v_response    record;
  v_attempts    int := 0;
BEGIN
  SELECT setting_value INTO v_token FROM public.settings
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = 'chatbot_bot_token';

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'chatbot_bot_token not set in settings');
  END IF;

  v_payload := jsonb_build_object('chat_id', p_chat_id, 'text', p_text);
  IF p_parse_mode IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('parse_mode', p_parse_mode);
  END IF;
  IF p_reply_to_message_id IS NOT NULL THEN
    v_payload := v_payload || jsonb_build_object('reply_to_message_id', p_reply_to_message_id);
  END IF;

  SELECT net.http_post(
    url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := v_payload
  ) INTO v_request_id;

  LOOP
    SELECT id, status_code, content, error_msg INTO v_response
    FROM net._http_response WHERE id = v_request_id;
    EXIT WHEN v_response.status_code IS NOT NULL OR v_response.error_msg IS NOT NULL OR v_attempts >= 40;
    PERFORM pg_sleep(0.5);
    v_attempts := v_attempts + 1;
  END LOOP;

  IF v_response.error_msg IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pg_net error: ' || v_response.error_msg);
  END IF;
  IF v_response.content IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'timeout waiting for Telegram response');
  END IF;

  BEGIN
    RETURN v_response.content::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'non-JSON response', 'raw', left(v_response.content, 500));
  END;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.paper_newt_send_message(bigint, text, text, bigint) TO authenticated, anon, service_role;

-- Re-point the nudge function to use paper_newt_send_message (@paper_newt_bot)
CREATE OR REPLACE FUNCTION public.nudge_peter_for_cpr_drafts()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_agency_id     uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id     uuid;
  v_run_started   timestamptz := now();
  v_now_ct        timestamp;
  v_today_ct      date;
  v_week_end      date;
  v_dow           int;
  v_report        record;
  v_peter_chat_id bigint;
  v_message       text;
  v_state         text;
  v_send_resp     jsonb;
  v_result        jsonb;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_nudge_peter' LIMIT 1;

  v_now_ct   := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct := v_now_ct::date;
  v_dow      := EXTRACT(DOW FROM v_today_ct)::int;
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF FOUND AND v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('skipped', 'already_sent', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF FOUND
     AND v_report.opener_text IS NOT NULL AND length(btrim(v_report.opener_text)) >= 100
     AND v_report.looking_next_week_text IS NOT NULL AND length(btrim(v_report.looking_next_week_text)) >= 50 THEN
    v_result := jsonb_build_object('skipped', 'drafts_ready', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  SELECT ttm.telegram_user_id INTO v_peter_chat_id
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner' AND coalesce(ttm.is_excluded, false) = false
  LIMIT 1;

  IF v_peter_chat_id IS NULL THEN
    v_result := jsonb_build_object('error', 'no_telegram_chat_id_for_peter');
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', 'No Telegram chat_id found for Owner', EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF NOT FOUND OR v_report IS NULL THEN
    v_state := 'no_row';
  ELSIF v_report.auto_ratio_pct IS NOT NULL AND v_report.fire_ratio_pct IS NOT NULL THEN
    v_state := 'form_filled_drafts_pending';
  ELSE
    v_state := 'form_empty';
  END IF;

  IF v_state = 'form_filled_drafts_pending' THEN
    v_message := E'📊 CPR check-in\n\n'
              || E'The form is filled but drafts aren''t in yet.\n\n'
              || E'⏳ Ping Claude to draft the opener + looking-ahead. Cron auto-sends at 11:59 PM CT once drafts land.\n\n'
              || 'Week ending: ' || v_week_end::text;
  ELSE
    v_message := E'📊 CPR check-in\n\n'
              || E'The CPR form isn''t filled in yet. Auto-send needs both form data + Claude drafts.\n\n'
              || E'Fill the form, then ping Claude.\n\n'
              || 'Week ending: ' || v_week_end::text;
  END IF;

  -- *** FIXED: use paper_newt_send_message (= @paper_newt_bot Peter has /start-ed)
  v_send_resp := public.paper_newt_send_message(v_peter_chat_id, v_message);

  IF v_send_resp IS NULL OR (v_send_resp->>'ok')::boolean IS NOT TRUE THEN
    v_result := jsonb_build_object(
      'nudged', false,
      'state', v_state,
      'telegram_error', v_send_resp->>'description',
      'telegram_code', v_send_resp->>'error_code',
      'send_response', v_send_resp,
      'week_ending_date', v_week_end
    );
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, output_summary, duration_seconds)
    VALUES (
      v_agency_id, v_recipe_id, v_run_started, 'failed',
      'Telegram send failed: ' || coalesce(v_send_resp->>'description', v_send_resp->>'error', 'unknown'),
      v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int
    );
    RETURN v_result;
  END IF;

  v_result := jsonb_build_object(
    'nudged', true,
    'state', v_state,
    'telegram_message_id', v_send_resp->'result'->>'message_id',
    'week_ending_date', v_week_end
  );
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'success', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$func$;
