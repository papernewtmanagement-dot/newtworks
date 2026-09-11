-- Peter 2026-09-10, LOCKED: when the health summary posts, the health reminder is
-- deleted, same as the work check-ins. Delete-then-post, so the channel keeps one
-- bubble and the summary still pings the team.
DO $mig$
DECLARE d text;
  a_decl text := $s$  v_behind_n int := 0;$s$;
  a_send text := $s$  v_response := public.telegram_send_message(v_chat_id, v_text);$s$;
BEGIN
  d := pg_get_functiondef('public.team_health_checkin_compile'::regproc);
  IF (length(d) - length(replace(d, a_decl, ''))) / length(a_decl) <> 1
     OR (length(d) - length(replace(d, a_send, ''))) / length(a_send) <> 1 THEN
    RAISE EXCEPTION 'health compile anchors not found exactly once';
  END IF;
  d := replace(d, a_decl, $s$  v_behind_n int := 0;
  v_reminder_msg_id bigint;
  v_tag_msg_id bigint;$s$);
  d := replace(d, a_send, $s$  -- LOCKED (Peter 2026-09-10): delete the health reminder (and any tag-missing
  -- nudge) before the summary posts, same as the work check-ins.
  SELECT reminder_message_id, tag_missing_message_id
    INTO v_reminder_msg_id, v_tag_msg_id
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = 'health_eve';
  IF v_reminder_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_reminder_msg_id);
  END IF;
  IF v_tag_msg_id IS NOT NULL THEN
    PERFORM public.telegram_delete_message(v_chat_id, v_tag_msg_id);
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);$s$);
  EXECUTE d;
END
$mig$;