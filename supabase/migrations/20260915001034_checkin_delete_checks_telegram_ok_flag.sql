-- Peter finding 2026-09-14: the old weekend sweep reported success on a delete
-- that Telegram refused, because nothing read the ok flag. The rebuilt chain
-- inherited the same hole: team_checkin_delete_message PERFORMed the API call,
-- threw the response away, and blanked the stored id either way.
--
-- telegram_api_call never raises on a Telegram-level failure. It returns
-- {"ok": false, "description": ...} with HTTP 200, so the old EXCEPTION guard
-- caught nothing. Now the response is read.
--
-- Terminal failures (the message is gone, too old, or not ours) clear the id so
-- a dead id is never retried. Every other failure (timeout, rate limit, network)
-- leaves the id in place for the next pass and reports nothing deleted.

CREATE OR REPLACE FUNCTION public.team_checkin_delete_message(
  p_agency_id uuid, p_chat_id bigint, p_checkin_type text, p_slot text,
  p_on_date date DEFAULT NULL::date, p_before_date date DEFAULT NULL::date)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_date date; v_msg bigint; v_floor date;
  v_resp jsonb; v_ok boolean; v_desc text; v_clear boolean;
BEGIN
  IF p_slot NOT IN ('reminder', 'summary', 'nag') THEN
    RAISE EXCEPTION 'team_checkin_delete_message: bad slot %', p_slot;
  END IF;
  IF p_chat_id IS NULL THEN RETURN NULL; END IF;

  -- Telegram only lets a bot delete its own message for 48 hours, so anything
  -- older than a week is not worth an API call.
  v_floor := COALESCE(p_on_date, p_before_date,
                      (now() AT TIME ZONE 'America/Chicago')::date) - 7;

  SELECT r.checkin_date,
         CASE p_slot
           WHEN 'reminder' THEN r.reminder_message_id
           WHEN 'summary'  THEN r.compile_results_message_id
           ELSE r.tag_missing_message_id END
    INTO v_date, v_msg
  FROM public.team_checkin_runs r
  WHERE r.agency_id = p_agency_id
    AND r.checkin_type = p_checkin_type
    AND r.checkin_date >= v_floor
    AND (p_on_date IS NULL OR r.checkin_date = p_on_date)
    AND (p_before_date IS NULL OR r.checkin_date < p_before_date)
    AND CASE p_slot
          WHEN 'reminder' THEN r.reminder_message_id
          WHEN 'summary'  THEN r.compile_results_message_id
          ELSE r.tag_missing_message_id END IS NOT NULL
  ORDER BY r.checkin_date DESC
  LIMIT 1;

  IF v_msg IS NULL THEN RETURN NULL; END IF;

  BEGIN
    v_resp := public.telegram_delete_message(p_chat_id, v_msg);
  EXCEPTION WHEN OTHERS THEN
    -- A failed delete must never stop the message that is about to go out.
    v_resp := jsonb_build_object('ok', false, 'description', 'exception: ' || SQLERRM);
  END;

  v_ok   := COALESCE((v_resp->>'ok')::boolean, false);
  v_desc := lower(COALESCE(v_resp->>'description', v_resp->>'error', ''));

  -- Message IDs reset on 2026-09-12 and every id from before that is now
  -- unreachable. Those come back "message to delete not found" and must be
  -- cleared, not retried forever.
  v_clear := v_ok
          OR v_desc LIKE '%message to delete not found%'
          OR v_desc LIKE '%message can''t be deleted%'
          OR v_desc LIKE '%message identifier is not specified%'
          OR v_desc LIKE '%chat not found%'
          OR v_desc LIKE '%bot was kicked%'
          OR v_desc LIKE '%bot is not a member%';

  IF NOT v_clear THEN
    -- Keep the id. The next kickoff, EOD, nag or sweep tries again.
    RETURN NULL;
  END IF;

  UPDATE public.team_checkin_runs
  SET reminder_message_id =
        CASE WHEN p_slot = 'reminder' THEN NULL ELSE reminder_message_id END,
      compile_results_message_id =
        CASE WHEN p_slot = 'summary' THEN NULL ELSE compile_results_message_id END,
      tag_missing_message_id =
        CASE WHEN p_slot = 'nag' THEN NULL ELSE tag_missing_message_id END,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_type = p_checkin_type
    AND checkin_date = v_date;

  -- Id cleared because it was unreachable, but no message actually came down.
  IF NOT v_ok THEN RETURN NULL; END IF;

  RETURN v_msg;
END;
$function$;

COMMENT ON FUNCTION public.team_checkin_delete_message(uuid, bigint, text, text, date, date) IS
'Deletes one stored check-in message and blanks its slot. Reads the Telegram ok flag: returns the message id only on a real delete, returns NULL and keeps the id when the failure is retryable. The single delete path for the whole check-in chain.';

-- The weekend sweep now reports what is still standing instead of only what it
-- believes it removed.
CREATE OR REPLACE FUNCTION public.team_checkin_sweep_weekend_eod()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_local timestamp; v_row record; v_chat_id bigint;
  v_deleted int := 0; v_msg bigint; v_left int := 0;
BEGIN
  BEGIN
    v_local := (now() AT TIME ZONE 'America/Chicago');

    IF extract(dow FROM v_local)::int <> 0 THEN
      RETURN jsonb_build_object('deleted', 0, 'skipped', 'not Sunday');
    END IF;
    -- Friday EOD goes out at 5 pm. Telegram stops allowing the delete 48 hours
    -- later, at 5 pm Sunday, so the last safe ticks are 3 pm and 4 pm.
    IF extract(hour FROM v_local)::int NOT BETWEEN 15 AND 16 THEN
      RETURN jsonb_build_object('deleted', 0, 'skipped', 'outside the 3-5 pm window');
    END IF;

    FOR v_row IN
      SELECT DISTINCT r.agency_id
      FROM public.team_checkin_runs r
      WHERE r.checkin_type = 'eod'
        AND r.reminder_message_id IS NOT NULL
        AND r.checkin_date >= v_local::date - 3
    LOOP
      SELECT setting_value::bigint INTO v_chat_id FROM public.settings
      WHERE agency_id = v_row.agency_id AND setting_key = 'telegram_team_group_chat_id';

      v_msg := public.team_checkin_delete_message(
        v_row.agency_id, v_chat_id, 'eod', 'reminder', NULL, v_local::date);
      IF v_msg IS NOT NULL THEN v_deleted := v_deleted + 1; END IF;
    END LOOP;

    SELECT count(*) INTO v_left
    FROM public.team_checkin_runs r
    WHERE r.checkin_type = 'eod'
      AND r.reminder_message_id IS NOT NULL
      AND r.checkin_date >= v_local::date - 3
      AND r.checkin_date < v_local::date;
  EXCEPTION WHEN OTHERS THEN
    -- Never raise: this rides the hourly automation tick.
    RETURN jsonb_build_object('deleted', v_deleted, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object('deleted', v_deleted, 'still_standing', v_left);
END;
$function$;
