-- Morning kickoff carries the PRIOR workday's commits with a hit or miss mark,
-- and the Telegram message is EDITED in place as people mark them. Peter spec
-- 2026-09-15.
--
-- The kickoff opens with a random quote, so the message can never be rebuilt
-- from scratch on a refresh or the quote would change on every edit. Instead
-- team_checkin_runs.reminder_text stores the message with a {{commits}} marker
-- where the block goes, and ONE function drops the live block into it. The
-- Telegram refresh and the Daily Kickoff page both call that one function, so
-- they cannot drift.

CREATE OR REPLACE FUNCTION public.kickoff_compose_message(
  p_agency_id uuid,
  p_date date,
  p_stored text
)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_text text := COALESCE(p_stored, '');
  v_prev date;
  v_block text;
BEGIN
  IF v_text = '' THEN RETURN NULL; END IF;
  IF position('{{commits}}' IN v_text) = 0 THEN RETURN v_text; END IF;

  -- The kickoff asks people to mark YESTERDAY's commit, the same way the Daily
  -- Kickoff page does. On a Monday that is Friday.
  v_prev := public.checklist_prev_workday(p_agency_id, p_date);
  IF v_prev IS NOT NULL THEN
    v_block := public.render_daily_commits_block(
      p_agency_id, v_prev, true, false,
      '🎯 Commits ' || to_char(v_prev, 'Mon DD'));
  END IF;

  IF v_block IS NULL OR btrim(v_block) = '' THEN
    v_text := replace(v_text, E'\n\n{{commits}}', '');
    v_text := replace(v_text, '{{commits}}', '');
  ELSE
    v_text := replace(v_text, '{{commits}}', v_block);
  END IF;

  RETURN v_text;
END;
$function$;

-- The Daily Kickoff page reads the same composed text the group sees.
CREATE OR REPLACE FUNCTION public.kickoff_morning_message(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
           'date', r.checkin_date,
           'sent_at', r.reminder_sent_at,
           'text', public.kickoff_compose_message(r.agency_id, r.checkin_date, r.reminder_text),
           'is_today', r.checkin_date = COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date))
  FROM public.team_checkin_runs r
  WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND r.checkin_type = 'morning'
    AND r.reminder_text IS NOT NULL
    AND r.checkin_date <= COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date)
  ORDER BY r.checkin_date DESC, r.reminder_sent_at DESC NULLS LAST
  LIMIT 1;
$function$;

-- Edits the standing kickoff message in place. Never deletes and reposts.
CREATE OR REPLACE FUNCTION public.kickoff_refresh_telegram(
  p_agency_id uuid DEFAULT NULL::uuid,
  p_date date DEFAULT NULL::date
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := COALESCE(p_agency_id, '126794dd-25ff-47d2-a436-724499733365'::uuid);
  v_date date := COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date);
  v_msg bigint; v_stored text; v_chat bigint; v_text text; v_resp jsonb;
BEGIN
  SELECT r.reminder_message_id, r.reminder_text INTO v_msg, v_stored
  FROM public.team_checkin_runs r
  WHERE r.agency_id = v_agency AND r.checkin_type = 'morning' AND r.checkin_date = v_date;

  IF v_msg IS NULL OR v_stored IS NULL THEN
    RETURN jsonb_build_object('refreshed', false, 'reason', 'no kickoff message on file for ' || v_date);
  END IF;

  SELECT s.setting_value::bigint INTO v_chat FROM public.settings s
  WHERE s.agency_id = v_agency AND s.setting_key = 'telegram_team_group_chat_id';
  IF v_chat IS NULL THEN
    RETURN jsonb_build_object('refreshed', false, 'reason', 'telegram_team_group_chat_id not set');
  END IF;

  v_text := public.kickoff_compose_message(v_agency, v_date, v_stored);
  IF v_text IS NULL OR btrim(v_text) = '' THEN
    RETURN jsonb_build_object('refreshed', false, 'reason', 'composed text empty');
  END IF;

  -- The kickoff sends as plain text, so the edit does too.
  v_resp := public.telegram_edit_message_text(v_chat, v_msg, v_text, NULL);

  IF (v_resp->>'ok')::boolean IS TRUE THEN
    RETURN jsonb_build_object('refreshed', true, 'message_id', v_msg);
  END IF;

  -- Telegram answers "message is not modified" when the text has not changed.
  -- That is normal here and is not a failure.
  RETURN jsonb_build_object('refreshed', false, 'message_id', v_msg,
    'reason', COALESCE(v_resp->>'description', v_resp->>'error', v_resp::text));
END;
$function$;