-- The wrap-up now shows every day by default. Two new pieces of state:
--   1. A per-person, per-day "not my last day" hide, so someone who is
--      mid-week can put it away until tomorrow.
--   2. An explicit "I am finished with it" stamp, so the day-done check
--      knows nothing is left to type. Separate from wrapup_done, which
--      keeps its existing meaning: all six answers are filled in.
-- Peter 2026-09-17.

-- One place that answers "is p_date this person's last workday of the CPR
-- week?" — office closures plus their own approved full-day time off. Lifted
-- out of my_wrapup_get so the hide guard and the reader agree by construction.
CREATE OR REPLACE FUNCTION public.wrapup_is_last_workday(p_team_member uuid, p_date date DEFAULT NULL::date)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT NOT EXISTS (
    SELECT 1
    FROM generate_series(me.d + 1, me.d + (6 - EXTRACT(DOW FROM me.d)::int), interval '1 day') g
    WHERE public.checklist_is_workday(me.agency_id, g::date)
      AND NOT EXISTS (
        SELECT 1 FROM public.time_off_requests r
        WHERE r.agency_id = me.agency_id
          AND r.requester_team_id = me.tm
          AND r.status = 'approved'
          AND r.request_type IN ('time_off_full_day', 'sick')
          AND COALESCE(r.partial_day, 'none') = 'none'
          AND g::date BETWEEN r.start_date AND COALESCE(r.end_date, r.start_date)
      )
  )
  FROM (
    SELECT t.id AS tm,
           t.agency_id AS agency_id,
           COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date) AS d
    FROM public.team t
    WHERE t.id = p_team_member
  ) me;
$fn$;

-- One row per person per day they put the wrap-up away. Reached only through
-- the SECURITY DEFINER functions below, so RLS is on with no policies.
CREATE TABLE IF NOT EXISTS public.wrapup_day_hides (
  agency_id       uuid NOT NULL,
  team_member_id  uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  hide_date       date NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, team_member_id, hide_date)
);
ALTER TABLE public.wrapup_day_hides ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS wrapup_finished_at timestamptz;

-- Hide or unhide today's wrap-up. Refused on their known last workday, which
-- is the same answer the screen uses to drop the control.
CREATE OR REPLACE FUNCTION public.my_wrapup_hide_set(p_on boolean, p_date date DEFAULT NULL::date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_date date := COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date);
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  IF p_on AND COALESCE(public.wrapup_is_last_workday(v_me, v_date), false) THEN
    RAISE EXCEPTION 'this is your last workday of the week, so the wrap-up stays' USING ERRCODE = '22023';
  END IF;

  IF p_on THEN
    INSERT INTO public.wrapup_day_hides (agency_id, team_member_id, hide_date)
    VALUES (v_agency, v_me, v_date)
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.wrapup_day_hides
     WHERE agency_id = v_agency AND team_member_id = v_me AND hide_date = v_date;
  END IF;

  RETURN jsonb_build_object('ok', true, 'hidden_today', COALESCE(p_on, false), 'date', v_date);
END;
$fn$;

-- "I have nothing left to type." Separate from wrapup_done on purpose.
CREATE OR REPLACE FUNCTION public.my_wrapup_finish(p_on boolean DEFAULT true, p_week_ending date DEFAULT NULL::date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
  v_report uuid;
  v_at timestamptz;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));

  SELECT r.id INTO v_report
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = v_agency AND r.week_ending_date = v_week_end;
  IF v_report IS NULL THEN
    RAISE EXCEPTION 'no CPR report for week ending %', v_week_end USING ERRCODE = '22023';
  END IF;

  v_at := CASE WHEN COALESCE(p_on, true) THEN now() ELSE NULL END;

  INSERT INTO public.weekly_cpr_team_detail
    (agency_id, weekly_cpr_report_id, team_member_id, wrapup_finished_at, updated_at)
  VALUES
    (v_agency, v_report, v_me, v_at, now())
  ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
  SET wrapup_finished_at = EXCLUDED.wrapup_finished_at,
      updated_at         = now();

  RETURN jsonb_build_object('ok', true, 'week_ending', v_week_end, 'wrapup_finished', v_at IS NOT NULL);
END;
$fn$;

-- Reader: same shape as before plus hidden_today and wrapup_finished, and the
-- last-workday answer now comes from the shared helper.
CREATE OR REPLACE FUNCTION public.my_wrapup_get(p_week_ending date DEFAULT NULL::date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
  v_report uuid;
  v_row public.weekly_cpr_team_detail%ROWTYPE;
  v_cue boolean := false;
  v_off_rest boolean := false;
  v_hidden boolean := false;
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
    v_cue := COALESCE(public.wrapup_is_last_workday(v_me, v_today), false);

    -- Distinguish "the office wraps today" from "you are out the rest of the week".
    SELECT EXISTS (
      SELECT 1
      FROM generate_series(v_today + 1, v_week_end, interval '1 day') g
      WHERE public.checklist_is_workday(v_agency, g::date)
    ) INTO v_off_rest;
    v_off_rest := v_cue AND v_off_rest;

    SELECT EXISTS (
      SELECT 1 FROM public.wrapup_day_hides h
      WHERE h.agency_id = v_agency AND h.team_member_id = v_me AND h.hide_date = v_today
    ) INTO v_hidden;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'me', v_me,
    'week_ending', v_week_end,
    'report_id', v_report,
    'detail_id', v_row.id,
    'wrapup_text', v_row.wrapup_text,
    'wrapup_done', COALESCE(v_row.wrapup_done, false),
    'wrapup_finished', v_row.wrapup_finished_at IS NOT NULL,
    'inbox_done', COALESCE(v_row.inbox_done, false),
    'code_reds', COALESCE(v_row.code_reds, ''),
    'code_yellows', COALESCE(v_row.code_yellows, ''),
    'wrap_cue', COALESCE(v_cue, false),
    'off_rest_of_week', COALESCE(v_off_rest, false),
    'hidden_today', COALESCE(v_hidden, false) AND NOT COALESCE(v_cue, false),
    'prompts', public.my_wrapup_prompts()
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.wrapup_is_last_workday(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_wrapup_hide_set(boolean, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_wrapup_finish(boolean, date) TO authenticated;
