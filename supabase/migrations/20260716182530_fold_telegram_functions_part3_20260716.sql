-- Rewrite functions 8-12: quarter_close, team_checkin_tag_missing, time_clock_edit_notifications, try_send_weekly_cpr_recap, verify_pending_cpr_sends

CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(p_agency_id uuid, p_quarter_ending_date date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_next_q_end date; v_carried int := 0; v_carried_value_total numeric := 0;
  v_smvc_annual numeric := 0; v_scorecard_annual numeric := 0; v_ot_basis_annual numeric := 0;
  v_closing_qtr_wins int := 0; v_pace numeric := 0; v_rate CONSTANT numeric := 0.01;
  v_next_budget numeric := 0; v_available_budget numeric := 0;
  v_pool_result jsonb; v_audit_result jsonb; v_result jsonb; v_pending_id uuid;
  v_peter_chat_id bigint; v_telegram_text text;
BEGIN
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  WITH carried AS (
    INSERT INTO public.prize_cart (agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value)
    SELECT agency_id, v_next_q_end, display_order, prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING prize_value
  )
  SELECT COUNT(*), COALESCE(SUM(prize_value), 0) INTO v_carried, v_carried_value_total FROM carried;

  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, p_quarter_ending_date);
  v_smvc_annual := COALESCE((v_pool_result->'basis'->>'on_time_smvc_dollars')::numeric, 0);
  v_scorecard_annual := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_ot_basis_annual := v_smvc_annual + v_scorecard_annual;

  SELECT COUNT(*) INTO v_closing_qtr_wins FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date > (p_quarter_ending_date - INTERVAL '13 weeks')
    AND week_ending_date <= p_quarter_ending_date
    AND won_the_week = true;

  v_pace := LEAST(1.0, v_closing_qtr_wins::numeric / 13.0);
  v_next_budget := ROUND(v_rate * v_ot_basis_annual * v_pace, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('1%% × on-time (SMVC $%s + Scorecard $%s) × %s/13 weeks won = $%s',
                 v_smvc_annual::text, v_scorecard_annual::text, v_closing_qtr_wins::text, v_next_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars, formula_note = EXCLUDED.formula_note;

  v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);

  INSERT INTO public.pending_prize_research (agency_id, quarter_ending_date, available_budget_dollars,
    carried_prize_count, carried_prize_value_total, status, notes)
  VALUES (p_agency_id, v_next_q_end, v_available_budget, v_carried, v_carried_value_total, 'pending',
    format('Quarter closed %s. %s prizes carried ($%s total). Budget $%s (1%% × OT basis × %s/13 wins). Available for new prizes: $%s.',
      p_quarter_ending_date::text, v_carried, v_carried_value_total::text,
      v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET available_budget_dollars = EXCLUDED.available_budget_dollars,
        carried_prize_count = EXCLUDED.carried_prize_count,
        carried_prize_value_total = EXCLUDED.carried_prize_value_total,
        status = 'pending', updated_at = now()
  RETURNING id INTO v_pending_id;

  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;

  INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
  VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
    format('Prize cart refresh — $%s available (Q ending %s)', v_available_budget::text, to_char(v_next_q_end, 'YYYY-MM-DD')),
    format('Quarter closed. %s prizes carried ($%s). Budget $%s (%s/13 wins). Available for new prizes: $%s. Run Claude session with op-rule "Newtworks quarter-end prize cart research" to research + verify links + propose new items.',
      v_carried, v_carried_value_total::text, v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text),
    v_pending_id, false);

  -- team.first_name/last_name instead of legacy ttm.telegram_first/last_name
  SELECT telegram_user_id INTO v_peter_chat_id FROM public.team
  WHERE agency_id = p_agency_id AND first_name = 'Peter' AND last_name = 'Story'
    AND telegram_user_id IS NOT NULL LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    v_telegram_text := '🏆 Prize cart refresh ready' || chr(10) || chr(10) ||
      'Quarter closed: ' || p_quarter_ending_date::text || ' -> next quarter ends ' || v_next_q_end::text || chr(10) ||
      '• ' || v_carried::text || ' prizes carried ($' || v_carried_value_total::text || ' total value)' || chr(10) ||
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13 (pace ' || ROUND(v_pace, 4)::text || ')' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text || chr(10) || chr(10) ||
      'Start a Claude session and say "run prize cart research" — Claude will use the ' ||
      '"Newtworks quarter-end prize cart research" operational rule to verify all links ' ||
      'and propose new prizes within budget.';

    BEGIN PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
      VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
        'Quarter-close nudge to Peter failed',
        format('Quarter=%s Error=%s', p_quarter_ending_date::text, SQLERRM), v_pending_id, false);
    END;
  ELSE
    INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
    VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
      'Quarter-close nudge to Peter: no telegram_user_id on team row',
      format('No telegram_user_id found for Peter Story on team in agency %s. Quarter=%s.',
        p_agency_id::text, p_quarter_ending_date::text), v_pending_id, false);
  END IF;

  v_result := jsonb_build_object('quarter_ending_date', p_quarter_ending_date,
    'next_quarter_ending_date', v_next_q_end, 'prizes_carried', v_carried,
    'carried_value_total', v_carried_value_total, 'closing_qtr_wins', v_closing_qtr_wins,
    'pace', ROUND(v_pace, 4), 'rate_pct', v_rate, 'ot_basis_annual', v_ot_basis_annual,
    'next_quarter_budget_dollars', v_next_budget, 'available_budget_dollars', v_available_budget,
    'pending_prize_research_id', v_pending_id, 'leaderboard_audit_result', v_audit_result,
    'ran_at', now());
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0; v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  -- Removed telegram_username fallback (all values were NULL). Use first_name only.
  FOR v_missing IN
    SELECT et.team_id AS id, et.first_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin') et
    LEFT JOIN public.team_checkins tc ON tc.team_id = et.team_id AND tc.agency_id = p_agency_id
      AND tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type
    WHERE tc.id IS NULL ORDER BY et.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  IF v_missing_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing: silent (everyone already in)', v_checkin_type));
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(), tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids, updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object('records_processed', v_missing_count,
    'output_summary', format('%s tag-missing%s: %s pending',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_missing_count));
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_clock_edit_notifications(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_peter_chat_id bigint;
  v_pending_sent int := 0; v_pending_fail int := 0;
  v_resolved_sent int := 0; v_resolved_fail int := 0; v_resolved_skip int := 0;
  r_group record; r_res record; v_msg text; v_resp jsonb; v_type_label text;
BEGIN
  SELECT t.telegram_user_id INTO v_peter_chat_id FROM public.team t
   WHERE t.agency_id = p_agency_id AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false
     AND COALESCE(t.is_excluded_pjsagencybot, false) = false
     AND t.telegram_user_id IS NOT NULL LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    FOR r_group IN
      SELECT tcer.team_member_id, t.first_name, t.last_name,
             array_agg(tcer.id ORDER BY tcer.submitted_at) AS request_ids,
             array_agg(tcer.edit_type ORDER BY tcer.submitted_at) AS edit_types,
             array_agg(tcer.punch_date ORDER BY tcer.submitted_at) AS punch_dates,
             array_agg(tcer.reason ORDER BY tcer.submitted_at) AS reasons
        FROM public.time_clock_edit_requests tcer
        JOIN public.team t ON t.id = tcer.team_member_id
       WHERE tcer.agency_id = p_agency_id AND tcer.status = 'pending'
         AND tcer.telegram_notified_at IS NULL
       GROUP BY tcer.team_member_id, t.first_name, t.last_name
    LOOP
      v_msg := E'⏰ Time clock edit request'
            || CASE WHEN array_length(r_group.request_ids, 1) > 1
                    THEN 's (' || array_length(r_group.request_ids, 1) || ')' ELSE '' END
            || E' from ' || r_group.first_name || ' ' || r_group.last_name || E'\n';

      FOR i IN 1..array_length(r_group.request_ids, 1) LOOP
        v_type_label := CASE r_group.edit_types[i]
          WHEN 'missed_shift' THEN 'Missed shift'
          WHEN 'missed_clock_in' THEN 'Missed clock-in'
          WHEN 'missed_clock_out' THEN 'Missed clock-out'
          WHEN 'wrong_time' THEN 'Wrong time'
          ELSE r_group.edit_types[i]
        END;
        v_msg := v_msg || E'\n• ' || to_char(r_group.punch_dates[i], 'Dy Mon DD')
              || ' — ' || v_type_label || E'\n  "' || left(r_group.reasons[i], 140) || '"';
      END LOOP;

      v_msg := v_msg || E'\n\nReview in Time Clock → Admin.';
      v_resp := public.paper_newt_send_message(v_peter_chat_id, v_msg);

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        UPDATE public.time_clock_edit_requests SET telegram_notified_at = now()
         WHERE id = ANY(r_group.request_ids);
        v_pending_sent := v_pending_sent + array_length(r_group.request_ids, 1);
      ELSE
        v_pending_fail := v_pending_fail + array_length(r_group.request_ids, 1);
      END IF;
    END LOOP;
  END IF;

  -- Resolved: read telegram_user_id off team, gated by is_excluded_pjsagencybot
  FOR r_res IN
    SELECT tcer.id, tcer.team_member_id, tcer.status, tcer.edit_type, tcer.punch_date, tcer.review_note,
           t.first_name,
           CASE WHEN COALESCE(t.is_excluded_pjsagencybot, false) = false
                THEN t.telegram_user_id ELSE NULL END AS telegram_user_id
      FROM public.time_clock_edit_requests tcer
      JOIN public.team t ON t.id = tcer.team_member_id
     WHERE tcer.agency_id = p_agency_id
       AND tcer.status IN ('approved','denied','cancelled')
       AND tcer.requester_notified_at IS NULL
     ORDER BY tcer.reviewed_at NULLS LAST LIMIT 20
  LOOP
    IF r_res.status = 'cancelled' THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1; CONTINUE;
    END IF;

    IF r_res.telegram_user_id IS NULL THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1; CONTINUE;
    END IF;

    v_type_label := CASE r_res.edit_type
      WHEN 'missed_shift' THEN 'missed shift'
      WHEN 'missed_clock_in' THEN 'missed clock-in'
      WHEN 'missed_clock_out' THEN 'missed clock-out'
      WHEN 'wrong_time' THEN 'wrong time'
      ELSE r_res.edit_type
    END;

    IF r_res.status = 'approved' THEN
      v_msg := format(E'✅ %s, your time clock edit request was approved.\n\n%s · %s',
                      r_res.first_name, to_char(r_res.punch_date, 'Dy Mon DD'), v_type_label);
    ELSE
      v_msg := format(E'❌ %s, your time clock edit request was denied.\n\n%s · %s',
                      r_res.first_name, to_char(r_res.punch_date, 'Dy Mon DD'), v_type_label);
    END IF;

    IF r_res.review_note IS NOT NULL AND length(btrim(r_res.review_note)) > 0 THEN
      v_msg := v_msg || E'\n\nPeter: "' || r_res.review_note || '"';
    END IF;

    v_resp := public.telegram_send_message(r_res.telegram_user_id, v_msg);
    UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;

    IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
      v_resolved_sent := v_resolved_sent + 1;
    ELSE v_resolved_fail := v_resolved_fail + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_pending_sent + v_resolved_sent + v_resolved_skip,
    'output_summary', format('pending→paper_newt: %s sent / %s failed · resolved→pjsagencybot: %s sent / %s failed / %s skipped',
                             v_pending_sent, v_pending_fail, v_resolved_sent, v_resolved_fail, v_resolved_skip));
END;
$function$;

CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public' SET statement_timeout TO '210000'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_now_ct timestamp; v_hour_ct int; v_dow int; v_week_end date; v_report record;
  v_send_result jsonb; v_recompute_res jsonb; v_recompute_note text := '';
  v_ok boolean; v_reason text; v_recipe_id uuid; v_day_label text; v_retry_note text;
  v_peter_chat bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_auto_send' LIMIT 1;

  v_now_ct := (now() AT TIME ZONE 'America/Chicago');
  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow := EXTRACT(DOW FROM v_now_ct)::int;

  IF v_hour_ct <> 6 THEN
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped: wrong-DST cron fire (intended 6 AM CT, got hour %s)', v_hour_ct));
    END IF;
    RETURN jsonb_build_object('skipped', true, 'reason', 'wrong_dst_hour', 'hour_ct', v_hour_ct);
  END IF;

  v_week_end := (v_now_ct::date) - ((v_dow + 1) % 7);
  v_day_label := CASE v_dow WHEN 6 THEN 'Sat' WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' ELSE 'Day' || v_dow::text END;
  v_retry_note := CASE v_dow WHEN 6 THEN ' Sun + Mon backups will retry.'
                             WHEN 0 THEN ' Mon backup will retry.'
                             WHEN 1 THEN ' No further auto-retry — manual send needed.'
                             ELSE '' END;

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    v_ok := false; v_reason := 'No weekly_cpr_reports row for week ending ' || v_week_end::text;
  ELSIF v_report.sent_to_team_at IS NOT NULL THEN
    v_ok := false; v_reason := 'already_sent at ' || v_report.sent_to_team_at::text;
  ELSIF COALESCE(v_report.send_attempt_count, 0) >= 3 THEN
    v_ok := false; v_reason := 'attempt_cap_reached (' || v_report.send_attempt_count || ' of 3)';
  ELSIF v_report.send_dispatched_at IS NOT NULL
        AND v_report.send_dispatched_at > now() - INTERVAL '90 minutes' THEN
    v_ok := false; v_reason := 'recent_dispatch_in_flight since ' || v_report.send_dispatched_at::text;
  ELSIF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    v_ok := false; v_reason := 'opener_not_ready (chars=' || COALESCE(length(btrim(v_report.opener_text)), 0) || ', need >=100)';
  ELSIF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    v_ok := false; v_reason := 'looking_ahead_not_ready (chars=' || COALESCE(length(btrim(v_report.looking_next_week_text)), 0) || ', need >=50)';
  ELSE v_ok := true; END IF;

  IF NOT v_ok THEN
    SELECT t.telegram_user_id INTO v_peter_chat FROM public.team t
     WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
       AND t.is_admin_backoffice = false AND coalesce(t.is_excluded_pjsagencybot, false) = false
       AND t.telegram_user_id IS NOT NULL LIMIT 1;

    IF v_peter_chat IS NOT NULL AND v_reason NOT LIKE 'already_sent%'
       AND v_reason NOT LIKE 'recent_dispatch%' THEN
      BEGIN PERFORM public.paper_newt_send_message(v_peter_chat,
        format(E'🟡 CPR %s send skipped: %s.%s', v_day_label, v_reason, v_retry_note));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped %s: %s', v_day_label, v_reason));
    END IF;

    RETURN jsonb_build_object('skipped', true, 'reason', v_reason, 'day', v_day_label,
                              'week_ending_date', v_week_end);
  END IF;

  BEGIN
    v_recompute_res := public.write_weekly_comp_v2(v_agency_id, v_week_end);
    v_recompute_note := format(' recompute_ok(rows=%s)', v_recompute_res->>'rows_updated');
  EXCEPTION WHEN OTHERS THEN
    v_recompute_note := format(' recompute_failed(%s)', SQLERRM);
  END;

  v_send_result := public.send_weekly_cpr_recap(v_agency_id, v_week_end);

  IF v_recipe_id IS NOT NULL THEN
    INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
    VALUES (v_agency_id, v_recipe_id, now(),
            CASE WHEN (v_send_result->>'success')::boolean THEN 'success' ELSE 'error' END,
            format('%s auto-send dispatched.%s verify_pending_cpr_sends will confirm. Result: %s',
                   v_day_label, v_recompute_note, v_send_result::text));
  END IF;

  RETURN jsonb_build_object('day', v_day_label, 'week_ending_date', v_week_end,
                            'recompute_note', v_recompute_note, 'send_result', v_send_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.verify_pending_cpr_sends()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id uuid; v_run_started timestamptz := now();
  v_report record; v_send_resp record; v_verify_resp record; v_content_jsonb jsonb;
  v_gmail_msg_id text; v_label_ids jsonb; v_gmail_ts timestamptz;
  v_verify_req_id bigint; v_api_key text; v_composio_user text; v_conn_acct text;
  v_confirmed int := 0; v_dispatched_verify int := 0; v_reset_error int := 0;
  v_reset_stale int := 0; v_escalated int := 0; v_still_pending int := 0;
  v_details jsonb := '[]'::jsonb; v_peter_chat bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'verify_pending_cpr_sends' LIMIT 1;

  IF NOT EXISTS (SELECT 1 FROM public.weekly_cpr_reports
    WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL AND send_dispatched_at IS NOT NULL) THEN
    RETURN jsonb_build_object('pending', 0, 'note', 'No pending sends to verify.');
  END IF;

  SELECT setting_value INTO v_api_key FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_composio_user FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_conn_acct FROM public.settings
   WHERE agency_id = v_agency_id AND setting_key = 'composio_gmail_account_id';

  SELECT t.telegram_user_id INTO v_peter_chat FROM public.team t
   WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false AND coalesce(t.is_excluded_pjsagencybot, false) = false
     AND t.telegram_user_id IS NOT NULL LIMIT 1;

  FOR v_report IN
    SELECT * FROM public.weekly_cpr_reports
     WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL AND send_dispatched_at IS NOT NULL
     ORDER BY send_dispatched_at
  LOOP
    IF v_report.gmail_message_id IS NULL THEN
      SELECT id, status_code, content, error_msg, created INTO v_send_resp
        FROM net._http_response WHERE id = v_report.send_request_id;

      IF v_send_resp.id IS NULL THEN
        IF v_report.send_dispatched_at < now() - INTERVAL '10 minutes' THEN
          UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
          v_reset_stale := v_reset_stale + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_stale_no_response', 'attempt', v_report.send_attempt_count);
        ELSE v_still_pending := v_still_pending + 1; END IF;

      ELSIF v_send_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN v_content_jsonb := v_send_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN v_content_jsonb := NULL; END;

        v_gmail_msg_id := v_content_jsonb #>> '{data,response_data,id}';

        IF v_gmail_msg_id IS NULL OR btrim(v_gmail_msg_id) = '' THEN
          UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'reset_no_msgid_in_2xx_body',
            'body', left(coalesce(v_send_resp.content, ''), 300));
        ELSE
          SELECT net.http_post(
            url := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID',
            headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
            body := jsonb_build_object('user_id', v_composio_user, 'connected_account_id', v_conn_acct,
              'arguments', jsonb_build_object('message_id', v_gmail_msg_id, 'user_id', 'me', 'format', 'metadata')),
            timeout_milliseconds := 60000
          ) INTO v_verify_req_id;

          UPDATE public.weekly_cpr_reports
             SET gmail_message_id = v_gmail_msg_id, gmail_verify_request_id = v_verify_req_id
           WHERE id = v_report.id;

          v_dispatched_verify := v_dispatched_verify + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 1, 'action', 'msgid_captured_verify_fired',
            'gmail_message_id', v_gmail_msg_id, 'verify_request_id', v_verify_req_id);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports SET send_dispatched_at = NULL, send_request_id = NULL WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
          'phase', 1, 'action', 'reset_send_error',
          'status_code', v_send_resp.status_code, 'error_msg', v_send_resp.error_msg,
          'body', left(coalesce(v_send_resp.content, ''), 300));
      END IF;

    ELSE
      SELECT id, status_code, content, error_msg, created INTO v_verify_resp
        FROM net._http_response WHERE id = v_report.gmail_verify_request_id;

      IF v_verify_resp.id IS NULL THEN
        IF v_report.send_dispatched_at < now() - INTERVAL '2 hours' THEN
          UPDATE public.weekly_cpr_reports
             SET send_dispatched_at = NULL, send_request_id = NULL,
                 gmail_message_id = NULL, gmail_verify_request_id = NULL
           WHERE id = v_report.id;
          v_reset_stale := v_reset_stale + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_verify_stale', 'attempt', v_report.send_attempt_count);
        ELSE v_still_pending := v_still_pending + 1; END IF;

      ELSIF v_verify_resp.status_code BETWEEN 200 AND 299 THEN
        BEGIN v_content_jsonb := v_verify_resp.content::jsonb;
        EXCEPTION WHEN OTHERS THEN v_content_jsonb := NULL; END;

        v_label_ids := v_content_jsonb #> '{data,labelIds}';

        BEGIN v_gmail_ts := (v_content_jsonb #>> '{data,messageTimestamp}')::timestamptz;
        EXCEPTION WHEN OTHERS THEN v_gmail_ts := NULL; END;

        IF v_label_ids IS NOT NULL AND v_label_ids @> '["SENT"]'::jsonb THEN
          UPDATE public.weekly_cpr_reports
             SET sent_to_team_at = COALESCE(v_gmail_ts, v_verify_resp.created, now()),
                 gmail_verified_at = now()
           WHERE id = v_report.id;
          v_confirmed := v_confirmed + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'gmail_confirmed_sent',
            'gmail_message_id', v_report.gmail_message_id,
            'gmail_message_timestamp', v_gmail_ts, 'labelIds', v_label_ids);
        ELSE
          UPDATE public.weekly_cpr_reports
             SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
                 send_dispatched_at = NULL, send_request_id = NULL
           WHERE id = v_report.id;
          v_reset_error := v_reset_error + 1;
          v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
            'phase', 2, 'action', 'reset_no_sent_label', 'labelIds', v_label_ids);
        END IF;

      ELSE
        UPDATE public.weekly_cpr_reports
           SET gmail_message_id = NULL, gmail_verify_request_id = NULL,
               send_dispatched_at = NULL, send_request_id = NULL
         WHERE id = v_report.id;
        v_reset_error := v_reset_error + 1;
        v_details := v_details || jsonb_build_object('week_ending_date', v_report.week_ending_date,
          'phase', 2, 'action', 'reset_gmail_fetch_error',
          'status_code', v_verify_resp.status_code, 'error_msg', v_verify_resp.error_msg,
          'body', left(coalesce(v_verify_resp.content, ''), 300));
      END IF;
    END IF;
  END LOOP;

  IF v_peter_chat IS NOT NULL THEN
    FOR v_report IN
      SELECT * FROM public.weekly_cpr_reports
       WHERE agency_id = v_agency_id AND sent_to_team_at IS NULL
         AND COALESCE(send_attempt_count, 0) >= 3
         AND escalation_alerted_at IS NULL
         AND week_ending_date >= CURRENT_DATE - INTERVAL '14 days'
    LOOP
      BEGIN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🔴🔴🔴 CPR RECAP — WEEK %s\nSend attempts exhausted (%s of 3). No Gmail confirmation.\nManual send required. Consider: SELECT public.send_weekly_cpr_recap(''%s''::uuid, ''%s''::date) after resetting send_attempt_count.',
                 v_report.week_ending_date, v_report.send_attempt_count,
                 v_agency_id, v_report.week_ending_date));
        UPDATE public.weekly_cpr_reports SET escalation_alerted_at = now() WHERE id = v_report.id;
        v_escalated := v_escalated + 1;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;

  IF (v_reset_error + v_reset_stale) > 0 AND v_peter_chat IS NOT NULL THEN
    BEGIN PERFORM public.paper_newt_send_message(v_peter_chat,
      format(E'🟡 CPR verify: %s errors / %s stale reset\n\n%s',
             v_reset_error, v_reset_stale, left(v_details::text, 1000)));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  IF v_recipe_id IS NOT NULL AND (v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated) > 0 THEN
    INSERT INTO public.automation_run_log
      (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
    VALUES (v_agency_id, v_recipe_id, v_run_started,
       CASE WHEN (v_reset_error + v_reset_stale + v_escalated) > 0 THEN 'partial' ELSE 'success' END,
       v_confirmed + v_dispatched_verify + v_reset_error + v_reset_stale + v_escalated,
       jsonb_build_object('confirmed', v_confirmed, 'verify_dispatched', v_dispatched_verify,
         'still_pending', v_still_pending, 'reset_error', v_reset_error,
         'reset_stale', v_reset_stale, 'escalated', v_escalated, 'details', v_details)::text,
       EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  END IF;

  RETURN jsonb_build_object('confirmed', v_confirmed, 'verify_dispatched', v_dispatched_verify,
    'still_pending', v_still_pending, 'reset_error', v_reset_error,
    'reset_stale', v_reset_stale, 'escalated', v_escalated, 'details', v_details);
END;
$function$;
