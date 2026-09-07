-- Peter 2026-09-07: "canceled" is spelled with one L everywhere, database values included.
-- Two tables still stored the two-L spelling as a status: time_clock_edit_requests and
-- time_off_requests. This moves the stored value, the CHECK constraints, and the three
-- functions that read or write it. No behavior change.

-- time_clock_edit_requests: 2 rows carry the old value today.
ALTER TABLE public.time_clock_edit_requests DROP CONSTRAINT IF EXISTS time_clock_edit_requests_status_check;
UPDATE public.time_clock_edit_requests SET status = 'canceled' WHERE status = 'cancelled';
ALTER TABLE public.time_clock_edit_requests
  ADD CONSTRAINT time_clock_edit_requests_status_check
  CHECK (status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'canceled'::text]));

-- time_off_requests: no rows carry the old value; the constraint still listed it.
ALTER TABLE public.time_off_requests DROP CONSTRAINT IF EXISTS time_off_requests_status_check;
UPDATE public.time_off_requests SET status = 'canceled' WHERE status = 'cancelled';
ALTER TABLE public.time_off_requests
  ADD CONSTRAINT time_off_requests_status_check
  CHECK (status = ANY (ARRAY['pending'::text, 'voting'::text, 'awaiting_decision'::text, 'approved'::text, 'denied'::text, 'expired'::text, 'canceled'::text, 'flagged_case_by_case'::text]));

-- Functions. Bodies unchanged apart from the spelling. Grants survive CREATE OR REPLACE.
CREATE OR REPLACE FUNCTION public.set_time_clock_edit_status(p_request_id uuid, p_new_status text, p_reviewer_user_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_resulting_entry_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  req_status TEXT;
BEGIN
  IF p_new_status NOT IN ('approved','denied','canceled') THEN
    RAISE EXCEPTION 'Invalid time_clock edit status: % (expected approved/denied/canceled)', p_new_status;
  END IF;

  SELECT status INTO req_status FROM public.time_clock_edit_requests
   WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit request % not found', p_request_id;
  END IF;
  IF req_status <> 'pending' THEN
    RAISE EXCEPTION 'Edit request % already resolved (status: %)', p_request_id, req_status;
  END IF;

  UPDATE public.time_clock_edit_requests
     SET status              = p_new_status,
         reviewed_at         = CASE WHEN p_new_status IN ('approved','denied') THEN NOW() ELSE reviewed_at END,
         reviewed_by_user_id = COALESCE(p_reviewer_user_id, reviewed_by_user_id),
         review_note         = COALESCE(p_note, review_note),
         resulting_entry_id  = COALESCE(p_resulting_entry_id, resulting_entry_id),
         updated_at          = NOW()
   WHERE id = p_request_id;
END $function$;

CREATE OR REPLACE FUNCTION public.cancel_time_clock_edit(p_request_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND NOT EXISTS (
       SELECT 1 FROM public.time_clock_edit_requests r
       WHERE r.id = p_request_id
         AND r.team_member_id = public.current_team_member_id()
     ) THEN
    RAISE EXCEPTION 'not authorized: only the person who raised this request can cancel it';
  END IF;
  PERFORM public.set_time_clock_edit_status(p_request_id, 'canceled');
END $function$;

CREATE OR REPLACE FUNCTION public.time_clock_edit_notifications(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
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
       AND tcer.status IN ('approved','denied','canceled')
       AND tcer.requester_notified_at IS NULL
     ORDER BY tcer.reviewed_at NULLS LAST LIMIT 20
  LOOP
    IF r_res.status = 'canceled' THEN
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
