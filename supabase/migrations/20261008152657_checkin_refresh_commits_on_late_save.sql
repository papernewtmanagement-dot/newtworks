CREATE OR REPLACE FUNCTION public.checkin_refresh_commits(p_agency_id uuid DEFAULT NULL::uuid, p_date date DEFAULT NULL::date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
-- A commit saved after the midday or end-of-day message went out left that
-- message saying Missing all day (Steph, 2026-10-08: saved 8 seconds after
-- midday sent). This swaps the commits block in today's already-sent midday
-- and end-of-day messages for the current one. The kickoff has its own refresh.
DECLARE
  v_agency uuid := COALESCE(p_agency_id, '126794dd-25ff-47d2-a436-724499733365'::uuid);
  v_date date := COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date);
  v_chat bigint; v_run record; v_block text; v_new text; v_resp jsonb;
  v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT s.setting_value::bigint INTO v_chat FROM public.settings s
  WHERE s.agency_id = v_agency AND s.setting_key = 'telegram_team_group_chat_id';
  IF v_chat IS NULL THEN
    RETURN jsonb_build_object('refreshed', false, 'reason', 'telegram_team_group_chat_id not set');
  END IF;

  FOR v_run IN
    SELECT r.id, r.checkin_type, r.reminder_message_id, r.reminder_text
    FROM public.team_checkin_runs r
    WHERE r.agency_id = v_agency AND r.checkin_date = v_date
      AND r.checkin_type IN ('midday', 'eod')
      AND r.reminder_message_id IS NOT NULL AND r.reminder_text IS NOT NULL
  LOOP
    -- Same block builder and same arguments team_message_build uses.
    v_block := public.render_daily_commits_block(v_agency, v_date, false, v_run.checkin_type = 'eod');
    IF v_block IS NULL OR position('🎯 Commits' IN v_run.reminder_text) = 0 THEN
      CONTINUE;
    END IF;

    v_new := regexp_replace(v_run.reminder_text, E'🎯 Commits(\\n• [^\\n]*)+',
                            replace(v_block, E'\\', E'\\\\'));
    IF v_new = v_run.reminder_text THEN
      CONTINUE;
    END IF;

    v_resp := public.telegram_edit_message_text(v_chat, v_run.reminder_message_id, v_new,
      CASE WHEN v_run.checkin_type = 'eod' THEN 'HTML' ELSE NULL END);

    IF (v_resp->>'ok')::boolean IS TRUE THEN
      UPDATE public.team_checkin_runs SET reminder_text = v_new, updated_at = now() WHERE id = v_run.id;
    END IF;

    v_out := v_out || jsonb_build_object('type', v_run.checkin_type,
      'ok', COALESCE((v_resp->>'ok')::boolean, false),
      'reason', v_resp->>'description');
  END LOOP;

  RETURN jsonb_build_object('refreshed', v_out);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.kickoff_commit_save(p_text text, p_source text, p_week integer DEFAULT NULL::integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_text text := btrim(COALESCE(p_text, ''));
  v_row jsonb;
BEGIN
  PERFORM public.require_login('staff');
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  IF v_text = '' THEN
    RAISE EXCEPTION 'commit is empty' USING ERRCODE = '22023';
  END IF;
  IF p_source NOT IN ('example', 'other') THEN
    RAISE EXCEPTION 'source must be example or other' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.daily_commits
    WHERE team_member_id = v_me AND commit_date = v_today
  ) THEN
    RAISE EXCEPTION 'your commit for today is already saved and cannot be changed'
      USING ERRCODE = '23505';
  END IF;

  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  INSERT INTO public.daily_commits (agency_id, team_member_id, commit_date, cycle_week, commit_text, source)
  VALUES (v_agency, v_me, v_today, p_week, left(v_text, 400), p_source)
  RETURNING to_jsonb(daily_commits) INTO v_row;

  BEGIN
    PERFORM public.kickoff_refresh_telegram(v_agency);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- A commit saved after midday or end of day went out updates those messages too.
  BEGIN
    PERFORM public.checkin_refresh_commits(v_agency, v_today);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_row;
END;
$fn$;
