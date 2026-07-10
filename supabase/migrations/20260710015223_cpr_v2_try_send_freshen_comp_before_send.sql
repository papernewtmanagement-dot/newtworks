-- try_send_weekly_cpr_recap: recompute write_weekly_comp_v2 right before send.
-- Picks up any last-minute health checkins, sales points edits, marketing pool changes, etc.
-- Wrapped in an exception handler so a recompute failure doesn't block the send (better to
-- ship slightly stale data than not ship at all — Sun/Mon backups can retry with fresher data).
--
-- Applied via Supabase MCP 2026-07-09; mirrored here for grep-ability + diff visibility.

CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '210000'
AS $function$
DECLARE
  v_agency_id      uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_now_ct         timestamp;
  v_hour_ct        int;
  v_dow            int;
  v_week_end       date;
  v_report         record;
  v_send_result    jsonb;
  v_recompute_res  jsonb;
  v_recompute_note text := '';
  v_ok             boolean;
  v_reason         text;
  v_recipe_id      uuid;
  v_day_label      text;
  v_retry_note     text;
  v_peter_chat     bigint;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'weekly_cpr_auto_send' LIMIT 1;

  v_now_ct  := (now() AT TIME ZONE 'America/Chicago');
  v_hour_ct := EXTRACT(HOUR FROM v_now_ct)::int;
  v_dow     := EXTRACT(DOW  FROM v_now_ct)::int;

  IF v_hour_ct <> 6 THEN
    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped: wrong-DST cron fire (intended 6 AM CT, got hour %s)', v_hour_ct));
    END IF;
    RETURN jsonb_build_object('skipped', true, 'reason', 'wrong_dst_hour', 'hour_ct', v_hour_ct);
  END IF;

  v_week_end := (v_now_ct::date) - ((v_dow + 1) % 7);

  v_day_label  := CASE v_dow WHEN 6 THEN 'Sat' WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon'
                             ELSE 'Day' || v_dow::text END;
  v_retry_note := CASE v_dow WHEN 6 THEN ' Sun + Mon backups will retry.'
                             WHEN 0 THEN ' Mon backup will retry.'
                             WHEN 1 THEN ' No further auto-retry - manual send needed.'
                             ELSE '' END;

  SELECT * INTO v_report FROM public.weekly_cpr_reports
   WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    v_ok := false;
    v_reason := 'No weekly_cpr_reports row for week ending ' || v_week_end::text;
  ELSIF v_report.sent_to_team_at IS NOT NULL THEN
    v_ok := false;
    v_reason := 'already_sent at ' || v_report.sent_to_team_at::text;
  ELSIF COALESCE(v_report.send_attempt_count, 0) >= 3 THEN
    v_ok := false;
    v_reason := 'attempt_cap_reached (' || v_report.send_attempt_count || ' of 3)';
  ELSIF v_report.send_dispatched_at IS NOT NULL
        AND v_report.send_dispatched_at > now() - INTERVAL '90 minutes' THEN
    v_ok := false;
    v_reason := 'recent_dispatch_in_flight since ' || v_report.send_dispatched_at::text;
  ELSIF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    v_ok := false;
    v_reason := 'opener_not_ready (chars=' ||
                COALESCE(length(btrim(v_report.opener_text)), 0) || ', need >=100)';
  ELSIF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    v_ok := false;
    v_reason := 'looking_ahead_not_ready (chars=' ||
                COALESCE(length(btrim(v_report.looking_next_week_text)), 0) || ', need >=50)';
  ELSE
    v_ok := true;
  END IF;

  IF NOT v_ok THEN
    SELECT ttm.telegram_user_id INTO v_peter_chat
      FROM public.team_telegram_map ttm
      JOIN public.team t ON t.id = ttm.team_id
     WHERE t.agency_id = v_agency_id AND t.role_level = 'Owner'
       AND t.is_admin_backoffice = false AND coalesce(ttm.is_excluded_pjsagencybot, false) = false
     LIMIT 1;

    IF v_peter_chat IS NOT NULL AND v_reason NOT LIKE 'already_sent%'
       AND v_reason NOT LIKE 'recent_dispatch%' THEN
      BEGIN
        PERFORM public.paper_newt_send_message(v_peter_chat,
          format(E'🟡 CPR %s send skipped: %s.%s',
                 v_day_label, v_reason, v_retry_note));
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    IF v_recipe_id IS NOT NULL THEN
      INSERT INTO public.automation_run_log (agency_id, recipe_id, run_at, status, output_summary)
      VALUES (v_agency_id, v_recipe_id, now(), 'success',
              format('Skipped %s: %s', v_day_label, v_reason));
    END IF;

    RETURN jsonb_build_object('skipped', true, 'reason', v_reason, 'day', v_day_label,
                              'week_ending_date', v_week_end);
  END IF;

  -- FRESHEN: recompute residual pool + carveouts + marketing + warning trigger right before send.
  -- Picks up any last-minute updates (health checkins that just landed, sales_points edits, etc).
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
                            'recompute_note', v_recompute_note,
                            'send_result', v_send_result);
END;
$function$;
