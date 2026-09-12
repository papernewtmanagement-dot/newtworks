-- The weekly wrap-up opens on the last workday of the CPR week. Peter
-- 2026-09-12: it should also open early for a teammate who is already off for
-- the rest of the week, because their last workday is today even though the
-- office keeps going. Only full-day absences count — a half day still leaves
-- them working that day, and remote is not away.
CREATE OR REPLACE FUNCTION public.my_wrapup_get(p_week_ending date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
  v_report uuid;
  v_row public.weekly_cpr_team_detail%ROWTYPE;
  v_cue boolean := false;
  v_off_rest boolean := false;
BEGIN
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_team_member');
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));

  SELECT r.id INTO v_report
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = v_agency AND r.week_ending_date = v_week_end;

  IF v_report IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report AND d.team_member_id = v_me;
  END IF;

  -- Only look ahead inside the week we are actually in.
  IF v_week_end = v_today + (6 - EXTRACT(DOW FROM v_today)::int) THEN
    SELECT NOT EXISTS (
      SELECT 1
      FROM generate_series(v_today + 1, v_week_end, interval '1 day') g
      WHERE public.checklist_is_workday(v_agency, g::date)
        AND NOT EXISTS (
          SELECT 1 FROM public.time_off_requests r
          WHERE r.agency_id = v_agency
            AND r.requester_team_id = v_me
            AND r.status = 'approved'
            AND r.request_type IN ('time_off_full_day', 'sick')
            AND COALESCE(r.partial_day, 'none') = 'none'
            AND g::date BETWEEN r.start_date AND COALESCE(r.end_date, r.start_date)
        )
    ) INTO v_cue;

    -- Distinguish "the office wraps today" from "you are out the rest of the week".
    SELECT EXISTS (
      SELECT 1
      FROM generate_series(v_today + 1, v_week_end, interval '1 day') g
      WHERE public.checklist_is_workday(v_agency, g::date)
    ) INTO v_off_rest;
    v_off_rest := v_cue AND v_off_rest;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'me', v_me,
    'week_ending', v_week_end,
    'report_id', v_report,
    'detail_id', v_row.id,
    'wrapup_text', v_row.wrapup_text,
    'wrapup_done', COALESCE(v_row.wrapup_done, false),
    'inbox_done', COALESCE(v_row.inbox_done, false),
    'code_reds', COALESCE(v_row.code_reds, ''),
    'code_yellows', COALESCE(v_row.code_yellows, ''),
    'wrap_cue', COALESCE(v_cue, false),
    'off_rest_of_week', COALESCE(v_off_rest, false),
    'prompts', public.my_wrapup_prompts()
  );
END;
$function$;
