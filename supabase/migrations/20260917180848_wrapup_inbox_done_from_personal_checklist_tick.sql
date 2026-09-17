-- The wrap-up form loses its "My inbox is cleared" checkbox (Peter 2026-09-17),
-- but inbox_done is still one of the four personal misses the CPR counts. It
-- now comes from the place the team already answers the same question every
-- day: the "Inbox cleared" item on the personal checklist. One source, no
-- second box asking the same thing.

-- Did this person tick their personal Inbox cleared item on this date?
CREATE OR REPLACE FUNCTION public.wrapup_inbox_cleared(p_team_member uuid, p_date date)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.daily_checklist_ticks k
    JOIN public.checklist_items i ON i.id = k.item_id
    JOIN public.team t ON t.id = p_team_member
    WHERE i.agency_id = t.agency_id
      AND i.scope = 'personal'
      AND i.item_key = 'inbox'
      AND k.tick_date = p_date
      AND k.ticked_for = p_team_member
  );
$fn$;

-- Writes that answer onto the CPR detail row for the week p_date sits in.
-- Only ever updates a row that already exists; a tick does not open a
-- wrap-up row that the person has not started.
CREATE OR REPLACE FUNCTION public.sync_wrapup_inbox_done(p_team_member uuid, p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_agency uuid;
  v_week_end date := p_date + (6 - EXTRACT(DOW FROM p_date)::int);
  v_report uuid;
BEGIN
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = p_team_member;
  IF v_agency IS NULL THEN RETURN; END IF;

  SELECT r.id INTO v_report
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = v_agency AND r.week_ending_date = v_week_end;
  IF v_report IS NULL THEN RETURN; END IF;

  UPDATE public.weekly_cpr_team_detail d
  SET inbox_done = public.wrapup_inbox_cleared(p_team_member, p_date),
      updated_at = now()
  WHERE d.weekly_cpr_report_id = v_report AND d.team_member_id = p_team_member;
END;
$fn$;

-- Ticking or unticking Inbox cleared keeps the CPR answer current, so it does
-- not matter whether the wrap-up is saved before or after the inbox is worked.
CREATE OR REPLACE FUNCTION public.daily_checklist_tick(p_item_id uuid, p_date date, p_on boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_scope text;
  v_key text;
  v_for uuid;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  IF p_date IS NULL OR p_date > v_today OR p_date < v_today - 14 THEN
    RAISE EXCEPTION 'tick date must be within the last two weeks' USING ERRCODE = '22023';
  END IF;
  SELECT i.scope, i.item_key INTO v_scope, v_key
  FROM public.checklist_items i WHERE i.id = p_item_id AND i.agency_id = v_agency;
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'unknown checklist item' USING ERRCODE = '22023';
  END IF;

  -- A personal item is ticked once per person. A team item stays one shared tick.
  v_for := CASE WHEN v_scope = 'personal' THEN v_me ELSE NULL END;

  IF p_on THEN
    INSERT INTO public.daily_checklist_ticks (agency_id, item_id, tick_date, ticked_by, ticked_for, ticked_at)
    VALUES (v_agency, p_item_id, p_date, v_me, v_for, now())
    ON CONFLICT (agency_id, item_id, tick_date, COALESCE(ticked_for, '00000000-0000-0000-0000-000000000000'::uuid))
    DO NOTHING;
  ELSE
    DELETE FROM public.daily_checklist_ticks
    WHERE agency_id = v_agency AND item_id = p_item_id AND tick_date = p_date
      AND ticked_for IS NOT DISTINCT FROM v_for;
  END IF;

  IF v_scope = 'personal' AND v_key = 'inbox' THEN
    PERFORM public.sync_wrapup_inbox_done(v_me, p_date);
  END IF;

  RETURN jsonb_build_object('ok', true, 'item_id', p_item_id, 'date', p_date, 'on', p_on, 'scope', v_scope);
END;
$fn$;

-- my_wrapup_save loses its p_inbox_done argument; the form no longer asks.
DROP FUNCTION IF EXISTS public.my_wrapup_save(jsonb, boolean, text, text, date);

CREATE OR REPLACE FUNCTION public.my_wrapup_save(p_parts jsonb, p_code_reds text DEFAULT NULL::text, p_code_yellows text DEFAULT NULL::text, p_week_ending date DEFAULT NULL::date)
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
  v_prompts jsonb := public.my_wrapup_prompts();
  v_text text := '';
  v_ans text;
  v_all boolean := true;
  v_inbox boolean;
  i int;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));
  -- Only this week or the one just closed. Nobody back-fills a month of wrap-ups.
  IF v_week_end > v_today + 6 OR v_week_end < v_today - 13 THEN
    RAISE EXCEPTION 'wrap-up week is out of range' USING ERRCODE = '22023';
  END IF;

  SELECT r.id INTO v_report
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = v_agency AND r.week_ending_date = v_week_end;
  IF v_report IS NULL THEN
    RAISE EXCEPTION 'no CPR report for week ending %', v_week_end USING ERRCODE = '22023';
  END IF;

  FOR i IN 1..6 LOOP
    v_ans := COALESCE(btrim(p_parts ->> (i - 1)), '');
    IF v_ans = '' THEN v_all := false; END IF;
    v_text := v_text || i || '. ' || (v_prompts -> (i - 1) ->> 'title') || E'\n' || v_ans || E'\n\n';
  END LOOP;
  v_text := btrim(v_text);

  v_inbox := public.wrapup_inbox_cleared(v_me, v_today);

  INSERT INTO public.weekly_cpr_team_detail
    (agency_id, weekly_cpr_report_id, team_member_id, wrapup_text, wrapup_done, inbox_done, code_reds, code_yellows, updated_at)
  VALUES
    (v_agency, v_report, v_me, v_text, v_all, v_inbox, p_code_reds, p_code_yellows, now())
  ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
  SET wrapup_text  = EXCLUDED.wrapup_text,
      wrapup_done  = EXCLUDED.wrapup_done,
      inbox_done   = EXCLUDED.inbox_done,
      code_reds    = EXCLUDED.code_reds,
      code_yellows = EXCLUDED.code_yellows,
      updated_at   = now();

  RETURN jsonb_build_object('ok', true, 'week_ending', v_week_end, 'wrapup_done', v_all, 'inbox_done', v_inbox);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.wrapup_inbox_cleared(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_wrapup_save(jsonb, text, text, date) TO authenticated;
