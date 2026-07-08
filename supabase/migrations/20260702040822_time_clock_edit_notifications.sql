
-- =========================================================================
-- dispatch_time_clock_edit_notifications()
-- Runs every 5 min via pg_cron. Two passes:
--   1. Pending requests with telegram_notified_at IS NULL → DM Peter, one
--      message per requester per cycle (batches multiple pending from same
--      requester into one DM). Marks all included rows notified.
--   2. Resolved requests (approved/denied/cancelled) with
--      requester_notified_at IS NULL → DM the requester via @paper_newt_bot
--      if they've /start-ed it (team_telegram_map lookup). Marks notified
--      regardless of send success — we don't want to retry indefinitely
--      against a bot the user hasn't started.
--
-- Direct-cron pattern (bypasses automation-runner): pure Postgres, no
-- Composio orchestration needed. Mirrors weekly_cpr_auto_send / nudge_peter.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.dispatch_time_clock_edit_notifications()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $fn$
DECLARE
  v_agency_id     uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_recipe_id     uuid;
  v_run_started   timestamptz := now();
  v_peter_chat_id bigint;
  v_pending_sent  int := 0;
  v_pending_fail  int := 0;
  v_resolved_sent int := 0;
  v_resolved_fail int := 0;
  v_resolved_skip int := 0;
  r_group         record;
  r_res           record;
  v_msg           text;
  v_resp          jsonb;
  v_type_label    text;
BEGIN
  SELECT id INTO v_recipe_id FROM public.automation_recipes
   WHERE agency_id = v_agency_id AND recipe_name = 'time_clock_edit_notifier' LIMIT 1;

  -- Resolve Peter's chat_id for pending-notification DMs
  SELECT ttm.telegram_user_id INTO v_peter_chat_id
    FROM public.team_telegram_map ttm
    JOIN public.team t ON t.id = ttm.team_id
   WHERE t.agency_id = v_agency_id
     AND t.role_level = 'Owner'
     AND coalesce(ttm.is_excluded, false) = false
   LIMIT 1;

  -- ===================================================================
  -- Pass 1: notify Peter of pending requests (grouped by requester)
  -- ===================================================================
  IF v_peter_chat_id IS NOT NULL THEN
    FOR r_group IN
      SELECT
        tcer.team_member_id,
        t.first_name,
        t.last_name,
        array_agg(tcer.id ORDER BY tcer.submitted_at) AS request_ids,
        array_agg(tcer.edit_type ORDER BY tcer.submitted_at) AS edit_types,
        array_agg(tcer.punch_date ORDER BY tcer.submitted_at) AS punch_dates,
        array_agg(tcer.reason ORDER BY tcer.submitted_at) AS reasons
      FROM public.time_clock_edit_requests tcer
      JOIN public.team t ON t.id = tcer.team_member_id
      WHERE tcer.agency_id = v_agency_id
        AND tcer.status = 'pending'
        AND tcer.telegram_notified_at IS NULL
      GROUP BY tcer.team_member_id, t.first_name, t.last_name
    LOOP
      -- Build message body: one line per pending request
      v_msg := E'⏰ Time clock edit request'
            || CASE WHEN array_length(r_group.request_ids, 1) > 1
                    THEN 's (' || array_length(r_group.request_ids, 1) || ')'
                    ELSE '' END
            || E' from ' || r_group.first_name || ' ' || r_group.last_name || E'\n';

      FOR i IN 1..array_length(r_group.request_ids, 1) LOOP
        v_type_label := CASE r_group.edit_types[i]
          WHEN 'missed_shift'     THEN 'Missed shift'
          WHEN 'missed_clock_in'  THEN 'Missed clock-in'
          WHEN 'missed_clock_out' THEN 'Missed clock-out'
          WHEN 'wrong_time'       THEN 'Wrong time'
          ELSE r_group.edit_types[i]
        END;
        v_msg := v_msg || E'\n• '
              || to_char(r_group.punch_dates[i], 'Dy Mon DD')
              || ' — ' || v_type_label
              || E'\n  "' || left(r_group.reasons[i], 140) || '"';
      END LOOP;

      v_msg := v_msg || E'\n\nReview in Time Clock → Admin.';

      v_resp := public.paper_newt_send_message(v_peter_chat_id, v_msg);

      IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
        UPDATE public.time_clock_edit_requests
           SET telegram_notified_at = now()
         WHERE id = ANY(r_group.request_ids);
        v_pending_sent := v_pending_sent + array_length(r_group.request_ids, 1);
      ELSE
        v_pending_fail := v_pending_fail + array_length(r_group.request_ids, 1);
      END IF;
    END LOOP;
  END IF;

  -- ===================================================================
  -- Pass 2: notify requesters of resolved requests
  -- ===================================================================
  FOR r_res IN
    SELECT
      tcer.id,
      tcer.team_member_id,
      tcer.status,
      tcer.edit_type,
      tcer.punch_date,
      tcer.review_note,
      t.first_name,
      ttm.telegram_user_id
    FROM public.time_clock_edit_requests tcer
    JOIN public.team t ON t.id = tcer.team_member_id
    LEFT JOIN public.team_telegram_map ttm ON ttm.team_id = tcer.team_member_id
                                          AND coalesce(ttm.is_excluded, false) = false
    WHERE tcer.agency_id = v_agency_id
      AND tcer.status IN ('approved', 'denied', 'cancelled')
      AND tcer.requester_notified_at IS NULL
    ORDER BY tcer.reviewed_at NULLS LAST
    LIMIT 20
  LOOP
    -- Cancelled requests: no notification needed (requester cancelled it themselves)
    IF r_res.status = 'cancelled' THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1;
      CONTINUE;
    END IF;

    -- No chat_id (never /start-ed the bot): mark notified and skip
    IF r_res.telegram_user_id IS NULL THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1;
      CONTINUE;
    END IF;

    v_type_label := CASE r_res.edit_type
      WHEN 'missed_shift'     THEN 'missed shift'
      WHEN 'missed_clock_in'  THEN 'missed clock-in'
      WHEN 'missed_clock_out' THEN 'missed clock-out'
      WHEN 'wrong_time'       THEN 'wrong time'
      ELSE r_res.edit_type
    END;

    IF r_res.status = 'approved' THEN
      v_msg := format(E'✅ %s, your time clock edit request was approved.\n\n%s · %s',
                      r_res.first_name,
                      to_char(r_res.punch_date, 'Dy Mon DD'),
                      v_type_label);
    ELSE  -- denied
      v_msg := format(E'❌ %s, your time clock edit request was denied.\n\n%s · %s',
                      r_res.first_name,
                      to_char(r_res.punch_date, 'Dy Mon DD'),
                      v_type_label);
    END IF;

    IF r_res.review_note IS NOT NULL AND length(btrim(r_res.review_note)) > 0 THEN
      v_msg := v_msg || E'\n\nPeter: "' || r_res.review_note || '"';
    END IF;

    v_resp := public.paper_newt_send_message(r_res.telegram_user_id, v_msg);

    -- Mark notified even on failure — don't retry indefinitely against
    -- users who haven't /start-ed the bot. Their in-app view is authoritative.
    UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;

    IF v_resp IS NOT NULL AND (v_resp->>'ok')::boolean IS TRUE THEN
      v_resolved_sent := v_resolved_sent + 1;
    ELSE
      v_resolved_fail := v_resolved_fail + 1;
    END IF;
  END LOOP;

  -- Log run
  INSERT INTO public.automation_run_log
    (agency_id, recipe_id, run_at, status, records_processed, output_summary, duration_seconds)
  VALUES (
    v_agency_id, v_recipe_id, v_run_started,
    CASE WHEN v_pending_fail + v_resolved_fail > 0 THEN 'partial' ELSE 'success' END,
    v_pending_sent + v_resolved_sent + v_resolved_skip,
    format('pending: %s sent / %s failed · resolved: %s sent / %s failed / %s skipped',
           v_pending_sent, v_pending_fail, v_resolved_sent, v_resolved_fail, v_resolved_skip),
    EXTRACT(EPOCH FROM (now() - v_run_started))::int
  );

  RETURN jsonb_build_object(
    'pending_sent',   v_pending_sent,
    'pending_failed', v_pending_fail,
    'resolved_sent',  v_resolved_sent,
    'resolved_failed',v_resolved_fail,
    'resolved_skipped', v_resolved_skip
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.automation_run_log
    (agency_id, recipe_id, run_at, status, error_message, duration_seconds)
  VALUES (v_agency_id, v_recipe_id, v_run_started, 'failed', SQLERRM,
          EXTRACT(EPOCH FROM (now() - v_run_started))::int);
  RAISE;
END;
$fn$;

-- Register recipe row for run-log surfacing
INSERT INTO public.automation_recipes (agency_id, recipe_name, cron_expression, internal_handler, is_active, trigger_type)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'time_clock_edit_notifier',
       '*/5 * * * *',
       'dispatch_time_clock_edit_notifications',
       true,
       'cron'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'time_clock_edit_notifier'
);

-- Schedule cron (idempotent)
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'time_clock_edit_notifier';
SELECT cron.schedule(
  'time_clock_edit_notifier',
  '*/5 * * * *',
  $$SELECT public.dispatch_time_clock_edit_notifications()$$
);
