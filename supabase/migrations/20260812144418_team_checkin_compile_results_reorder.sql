CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_dow int;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_type_label text;
  v_block record;
  v_cpr_id uuid;
  v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_fit_url text := 'https://newtworks.vercel.app/handbook/newtworks-native-glossary-fit';
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  v_type_label := CASE v_checkin_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_checkin_type) END;

  -- Write the authoritative weekly_cpr_reports row FIRST. render_team_status_block then
  -- reads sales points back out of that record instead of recomputing it a second time.
  -- Peter directive 2026-08-12: compute once, save to the one record, read from that record.
  -- (Quotes stays a live calculation in render_team_status_block — quotes_total_net on
  -- weekly_cpr_reports is a different metric, from the CPR debt/penalty system, not the
  -- self-reported Telegram quotes number. See get_team_checkin_totals comment.)
  v_cpr_id := public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, v_today, v_checkin_type,
    '📊 ' || v_type_label || ' ' || to_char(v_today, 'Mon DD')
  );
  v_text := v_block.block_text;

  IF v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  -- Friday EOD wrapup addendum.
  -- Requirement list is the six items on the processes manual page
  -- "Daily Wrap-up" item 20 (Weekly wrap-up email). Manual is authoritative
  -- (Peter directive 2026-08-07); keep the two lists identical.
  -- The FIT Scorecard line is a reminder pointer, not a wrap-up email requirement.
  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Weekly wrapup — email paper.newt.management@gmail.com:\n\n'
      || E'Remember your <a href="' || v_fit_url || E'">FIT Scorecard</a>.\n\n'
      || E'1. Life and annuity status — your book, pending apps, upcoming reviews.\n'
      || E'2. Lapse/cancel trends + individual highlights.\n'
      || E'3. Obstacles you hit this week + the solutions you propose.\n'
      || E'4. Your plan for a 1% sales points increase next week.\n'
      || E'5. One recommendation to make the office more efficient.\n'
      || E'6. Brags on each teammate — something that matched our mission or their job description.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_block.fresh_count,
      expected_count = v_block.expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_block.fresh_count + v_block.carried_count,
    'output_summary', format('%s compile%s: %s/%s reporting; team %s/%s; cpr_id=%s',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_block.fresh_count, v_block.expected_count,
      v_block.team_total_quotes, v_block.team_total_sales, v_cpr_id)
  );
END;
$function$;
