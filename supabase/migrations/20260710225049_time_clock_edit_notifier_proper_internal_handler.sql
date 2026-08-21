-- Rewrite the notifier as a proper INTERNAL handler for the automation-runner.
-- The old public.dispatch_time_clock_edit_notifications() had:
--   - Zero-arg signature (incompatible with run_internal_recipe's (uuid,uuid) call)
--   - Hardcoded agency_id (couldn't be reused across agencies)
--   - Wrote its OWN automation_run_log row (runner writes one too → double-log)
--   - dispatch_* name prefix (misleading — it's pure-SQL, not edge-fn dispatch)
--
-- New public.time_clock_edit_notifications(p_agency_id, p_recipe_id):
--   - Correct signature for run_internal_recipe RPC path
--   - Uses passed agency_id
--   - No self-inserted log row (runner handles it)
--   - Returns { records_processed, output_summary } jsonb per convention

CREATE OR REPLACE FUNCTION public.time_clock_edit_notifications(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $function$
DECLARE
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
  -- Peter's Telegram user_id for the paper_newt bot (owner, not admin_backoffice)
  SELECT ttm.telegram_user_id INTO v_peter_chat_id
    FROM public.team_telegram_map ttm
    JOIN public.team t ON t.id = ttm.team_id
   WHERE t.agency_id = p_agency_id
     AND t.role_level = 'Owner'
     AND t.is_admin_backoffice = false
     AND COALESCE(ttm.is_excluded_pjsagencybot, false) = false
   LIMIT 1;

  -- 1. PENDING requests → DM Peter (grouped by requester)
  IF v_peter_chat_id IS NOT NULL THEN
    FOR r_group IN
      SELECT tcer.team_member_id, t.first_name, t.last_name,
             array_agg(tcer.id           ORDER BY tcer.submitted_at) AS request_ids,
             array_agg(tcer.edit_type    ORDER BY tcer.submitted_at) AS edit_types,
             array_agg(tcer.punch_date   ORDER BY tcer.submitted_at) AS punch_dates,
             array_agg(tcer.reason       ORDER BY tcer.submitted_at) AS reasons
        FROM public.time_clock_edit_requests tcer
        JOIN public.team t ON t.id = tcer.team_member_id
       WHERE tcer.agency_id = p_agency_id
         AND tcer.status = 'pending'
         AND tcer.telegram_notified_at IS NULL
       GROUP BY tcer.team_member_id, t.first_name, t.last_name
    LOOP
      v_msg := E'⏰ Time clock edit request'
            || CASE WHEN array_length(r_group.request_ids, 1) > 1
                    THEN 's (' || array_length(r_group.request_ids, 1) || ')' ELSE '' END
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

  -- 2. RESOLVED requests → DM the requester (skip cancelled + no-telegram)
  FOR r_res IN
    SELECT tcer.id, tcer.team_member_id, tcer.status, tcer.edit_type, tcer.punch_date, tcer.review_note,
           t.first_name, ttm.telegram_user_id
      FROM public.time_clock_edit_requests tcer
      JOIN public.team t ON t.id = tcer.team_member_id
      LEFT JOIN public.team_telegram_map ttm
             ON ttm.team_id = tcer.team_member_id
            AND COALESCE(ttm.is_excluded_pjsagencybot, false) = false
     WHERE tcer.agency_id = p_agency_id
       AND tcer.status IN ('approved','denied','cancelled')
       AND tcer.requester_notified_at IS NULL
     ORDER BY tcer.reviewed_at NULLS LAST
     LIMIT 20
  LOOP
    IF r_res.status = 'cancelled' THEN
      UPDATE public.time_clock_edit_requests SET requester_notified_at = now() WHERE id = r_res.id;
      v_resolved_skip := v_resolved_skip + 1;
      CONTINUE;
    END IF;

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
    ELSE
      v_resolved_fail := v_resolved_fail + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_pending_sent + v_resolved_sent + v_resolved_skip,
    'output_summary',    format('pending→paper_newt: %s sent / %s failed · resolved→pjsagencybot: %s sent / %s failed / %s skipped',
                                v_pending_sent, v_pending_fail, v_resolved_sent, v_resolved_fail, v_resolved_skip)
  );
END;
$function$;

-- Drop the old function (wrong signature, wrote its own log, hardcoded agency, never actually wired)
DROP FUNCTION IF EXISTS public.dispatch_time_clock_edit_notifications();

-- Rewire the recipe to use the new handler via the pure-SQL INTERNAL path
UPDATE public.automation_recipes
SET internal_handler = 'time_clock_edit_notifications',
    composio_action  = 'INTERNAL',
    is_active        = true,
    updated_at       = NOW()
WHERE id = '24986154-d523-4076-8664-a3a53db9bc81';
