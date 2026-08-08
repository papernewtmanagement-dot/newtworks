-- Repoint nudge_peter_for_cpr_drafts "form filled" test away from auto_ratio_pct/fire_ratio_pct,
-- which are being dropped. New test: any non-back-office teammate has quotes_discussed populated
-- for the week. Claims/non-pay columns are NOT usable here -- they all DEFAULT 0, never null.
CREATE OR REPLACE FUNCTION public.nudge_peter_for_cpr_drafts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id uuid;
  v_run_started timestamptz := now();
  v_now_ct timestamp;
  v_today_ct date;
  v_hour_ct int;
  v_week_end date;
  v_dow int;
  v_report record;
  v_peter_chat_id bigint;
  v_message text;
  v_state text;
  v_form_filled boolean;
  v_send_resp jsonb;
  v_result jsonb;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_nudge_peter' LIMIT 1;

  v_now_ct := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct := v_now_ct::date;
  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow := EXTRACT(DOW FROM v_today_ct)::int;
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  IF v_hour_ct <> 18 OR v_dow NOT IN (0, 6) THEN
    v_result := jsonb_build_object('skipped', 'wrong_dst_cron_fire', 'hour_ct', v_hour_ct, 'dow_ct', v_dow);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'success',
            'Skipped: wrong-DST cron fire (intended Sat/Sun 6 PM CT, got DOW ' || v_dow || ' hour ' || v_hour_ct || ')',
            EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF FOUND AND v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('skipped', 'already_sent', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF FOUND AND v_report.opener_text IS NOT NULL AND length(btrim(v_report.opener_text)) >= 100
     AND v_report.looking_next_week_text IS NOT NULL AND length(btrim(v_report.looking_next_week_text)) >= 50 THEN
    v_result := jsonb_build_object('skipped', 'drafts_ready', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  SELECT t.telegram_user_id INTO v_peter_chat_id FROM public.team t
  WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
    AND t.is_admin_backoffice = false AND coalesce(t.is_excluded_pjsagencybot, false) = false
    AND t.telegram_user_id IS NOT NULL LIMIT 1;

  IF v_peter_chat_id IS NULL THEN
    v_result := jsonb_build_object('error', 'no_telegram_user_id_for_peter');
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', 'No telegram_user_id found for Owner', EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  IF v_report.id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.weekly_cpr_team_detail d
      JOIN public.team t ON t.id = d.team_member_id
      WHERE d.weekly_cpr_report_id = v_report.id
        AND NOT COALESCE(t.is_admin_backoffice, false)
        AND COALESCE(t.role_level, '') <> 'Owner'
        AND d.quotes_discussed IS NOT NULL
    ) INTO v_form_filled;
  ELSE
    v_form_filled := false;
  END IF;

  IF v_report.id IS NULL THEN v_state := 'no_row';
  ELSIF v_form_filled THEN v_state := 'form_filled_drafts_pending';
  ELSE v_state := 'form_empty'; END IF;

  IF v_state = 'form_filled_drafts_pending' THEN
    v_message := E'📊 CPR check-in\n\nThe form is filled but drafts aren''t in yet.\n\n⏳ Ping Claude to draft the opener + looking-ahead. Cron auto-sends at 6 AM CT once drafts land.\n\nWeek ending: ' || v_week_end::text;
  ELSE
    v_message := E'📊 CPR check-in\n\nThe CPR form isn''t filled in yet. Auto-send needs both form data + Claude drafts.\n\nFill the form, then ping Claude.\n\nWeek ending: ' || v_week_end::text;
  END IF;

  v_send_resp := public.paper_newt_send_message(v_peter_chat_id, v_message);

  IF v_send_resp IS NULL OR (v_send_resp->>'ok')::boolean IS NOT TRUE THEN
    v_result := jsonb_build_object('nudged', false, 'state', v_state,
      'telegram_error', v_send_resp->>'description', 'telegram_code', v_send_resp->>'error_code',
      'send_response', v_send_resp, 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed',
            'Telegram send failed: ' || coalesce(v_send_resp->>'description', v_send_resp->>'error', 'unknown'),
            v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  v_result := jsonb_build_object('nudged', true, 'state', v_state,
    'telegram_message_id', v_send_resp->'result'->>'message_id', 'week_ending_date', v_week_end);
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'success', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$function$;
