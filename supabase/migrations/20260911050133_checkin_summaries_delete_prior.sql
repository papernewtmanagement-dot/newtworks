-- Peter 2026-09-10, LOCKED:
--  * When the EOD summary posts, that day's midday summary is deleted.
--  * When the morning kickoff posts, the prior EOD summary is deleted.
-- Same delete-then-post pattern as the reminders, so the channel stays at one live bubble.
DO $mig$
DECLARE d text;
  a_decl text := $s$v_reminder_msg_id bigint; v_tag_msg_id bigint;$s$;
  a_send text := $s$  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);$s$;
BEGIN
  d := pg_get_functiondef('public.team_checkin_compile_results'::regproc);
  IF (length(d) - length(replace(d, a_decl, ''))) / length(a_decl) <> 1
     OR (length(d) - length(replace(d, a_send, ''))) / length(a_send) <> 1 THEN
    RAISE EXCEPTION 'compile anchors not found exactly once';
  END IF;
  d := replace(d, a_decl, a_decl || ' v_midday_summary_msg_id bigint;');
  d := replace(d, a_send, $s$  -- LOCKED (Peter 2026-09-10): the EOD summary replaces that day's midday summary.
  IF v_checkin_type = 'eod' THEN
    SELECT compile_results_message_id INTO v_midday_summary_msg_id
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = 'midday';
    IF v_midday_summary_msg_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_midday_summary_msg_id);
    END IF;
  END IF;

$s$ || a_send);
  EXECUTE d;
END
$mig$;

DO $mig$
DECLARE d text;
  a_decl text := $s$v_prior_outcome record; v_outcome_line text;$s$;
  a_send text := $s$  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);$s$;
BEGIN
  d := pg_get_functiondef('public.team_checkin_send_reminder'::regproc);
  IF (length(d) - length(replace(d, a_decl, ''))) / length(a_decl) <> 1
     OR (length(d) - length(replace(d, a_send, ''))) / length(a_send) <> 1 THEN
    RAISE EXCEPTION 'reminder anchors not found exactly once';
  END IF;
  d := replace(d, a_decl, a_decl || ' v_prior_eod_summary_msg_id bigint;');
  d := replace(d, a_send, $s$  -- LOCKED (Peter 2026-09-10): the morning kickoff replaces the prior EOD summary.
  IF v_checkin_type = 'morning' THEN
    SELECT compile_results_message_id INTO v_prior_eod_summary_msg_id
    FROM public.team_checkin_runs
    WHERE agency_id = p_agency_id AND checkin_type = 'eod'
      AND checkin_date < v_today AND compile_results_message_id IS NOT NULL
    ORDER BY checkin_date DESC LIMIT 1;
    IF v_prior_eod_summary_msg_id IS NOT NULL THEN
      PERFORM public.telegram_delete_message(v_chat_id, v_prior_eod_summary_msg_id);
    END IF;
  END IF;

$s$ || a_send);
  EXECUTE d;
END
$mig$;