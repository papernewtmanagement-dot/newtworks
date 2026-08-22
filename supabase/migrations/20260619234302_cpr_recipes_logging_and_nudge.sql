-- 1. Register the two CPR cron recipes so runs can be logged and surfaced in dashboards
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, is_active
) VALUES
(
  '126794dd-25ff-47d2-a436-724499733365',
  'weekly_cpr_auto_send',
  'Auto-sends the Weekly CPR Recap to the team. Cron fires Sat 23:59 CT and Sun 23:59 CT. Calls public.try_send_weekly_cpr_recap() which finds the most recent Saturday in CT, checks readiness (opener+LA populated, not already sent), and fires send_weekly_cpr_recap() with dynamic team-table recipient lookup.',
  'cron', '59 4 * * 0,1', true
),
(
  '126794dd-25ff-47d2-a436-724499733365',
  'weekly_cpr_nudge_peter',
  'Nudges Peter via Telegram if CPR drafts aren''t ready by Sat 6pm CT (Sun 6pm CT backup). Skips silently if drafts are already in or the recap is already sent.',
  'cron', '0 23 * * 0,6', true
)
ON CONFLICT DO NOTHING;

-- 2. Nudge function. Reads current state of the week's CPR row, sends a tailored Telegram to Peter.
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
  v_send_id       bigint;
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

  -- Already sent → silent skip
  IF FOUND AND v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('skipped', 'already_sent', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  -- Drafts already in → silent skip (no nudge needed)
  IF FOUND
     AND v_report.opener_text IS NOT NULL AND length(btrim(v_report.opener_text)) >= 100
     AND v_report.looking_next_week_text IS NOT NULL AND length(btrim(v_report.looking_next_week_text)) >= 50 THEN
    v_result := jsonb_build_object('skipped', 'drafts_ready', 'week_ending_date', v_week_end);
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'skipped', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  -- Look up Peter's Telegram chat id
  SELECT ttm.telegram_user_id INTO v_peter_chat_id
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner' AND coalesce(ttm.is_excluded, false) = false
  LIMIT 1;

  IF v_peter_chat_id IS NULL THEN
    v_result := jsonb_build_object('error', 'no_telegram_chat_id_for_peter');
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', 'No Telegram chat_id found for Owner in team_telegram_map', EXTRACT(EPOCH FROM (now() - v_run_started))::int);
    RETURN v_result;
  END IF;

  -- Determine state and build the message
  IF NOT FOUND OR v_report IS NULL THEN
    v_state := 'no_row';
  ELSIF v_report.auto_ratio_pct IS NOT NULL AND v_report.fire_ratio_pct IS NOT NULL THEN
    v_state := 'form_filled_drafts_pending';
  ELSE
    v_state := 'form_empty';
  END IF;

  IF v_state = 'form_filled_drafts_pending' THEN
    v_message := E'📊 *CPR check-in*\n\n'
              || E'The form is filled but drafts aren''t in yet.\n\n'
              || E'⏳ Ping Claude to draft the opener + looking-ahead. Cron auto-sends at 11:59 PM CT once drafts land.\n\n'
              || 'Week ending: ' || v_week_end::text;
  ELSE
    v_message := E'📊 *CPR check-in*\n\n'
              || E'The CPR form isn''t filled in yet. Auto-send needs both form data + Claude drafts.\n\n'
              || E'Fill the form, then ping Claude.\n\n'
              || 'Week ending: ' || v_week_end::text;
  END IF;

  SELECT public.telegram_send_message(v_peter_chat_id, v_message, 'Markdown') INTO v_send_id;

  v_result := jsonb_build_object('nudged', true, 'state', v_state, 'message_request_id', v_send_id, 'week_ending_date', v_week_end);
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'success', v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.nudge_peter_for_cpr_drafts() TO authenticated, anon, service_role;

-- 3. Update try_send_weekly_cpr_recap to log every run
CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_agency_id   uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id   uuid;
  v_run_started timestamptz := now();
  v_now_ct      timestamp;
  v_today_ct    date;
  v_week_end    date;
  v_dow         int;
  v_report      record;
  v_send_res    jsonb;
  v_status      text;
  v_err         text;
  v_result      jsonb;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_auto_send' LIMIT 1;

  v_now_ct   := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct := v_now_ct::date;
  v_dow      := EXTRACT(DOW FROM v_today_ct)::int;
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    v_result := jsonb_build_object('fired', false, 'skipped', 'no_report_row', 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSIF v_report.sent_to_team_at IS NOT NULL THEN
    v_result := jsonb_build_object('fired', false, 'skipped', 'already_sent', 'sent_to_team_at', v_report.sent_to_team_at);
    v_status := 'skipped';
  ELSIF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    v_result := jsonb_build_object('fired', false, 'skipped', 'opener_not_ready', 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSIF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    v_result := jsonb_build_object('fired', false, 'skipped', 'looking_ahead_not_ready', 'week_ending_date', v_week_end);
    v_status := 'skipped';
  ELSE
    v_send_res := public.send_weekly_cpr_recap(v_agency_id, v_week_end);
    v_result   := jsonb_build_object('fired', true, 'week_ending_date', v_week_end, 'send_result', v_send_res);
    IF (v_send_res->>'success')::boolean = true THEN
      v_status := 'success';
    ELSE
      v_status := 'failed';
      v_err    := v_send_res->>'error';
    END IF;
  END IF;

  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, output_summary, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, v_status, v_err, v_result::text, EXTRACT(EPOCH FROM (now() - v_run_started))::int);

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM, EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$func$;

-- 4. Schedule the nudge cron (Sat 18:00 CT + Sun 18:00 CT = 23:00 UTC in CDT)
DO $$
DECLARE v_jid bigint;
BEGIN
  SELECT jobid INTO v_jid FROM cron.job WHERE jobname = 'weekly_cpr_nudge_peter';
  IF v_jid IS NOT NULL THEN PERFORM cron.unschedule(v_jid); END IF;
END $$;

SELECT cron.schedule(
  'weekly_cpr_nudge_peter',
  '0 23 * * 0,6',
  $cmd$ SELECT public.nudge_peter_for_cpr_drafts(); $cmd$
);
