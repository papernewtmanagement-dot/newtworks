-- Peter 2026-09-25: Cassie's Code Red (Thu Sep 24) and Code Yellow (Mon Sep 21) were missing
-- from the CPR for the week ending 2026-09-26.
--
-- Cause: the Checklist tab saves the weekly wrap-up through my_wrapup_save with
-- p_code_reds = NULL and p_code_yellows = NULL, and my_wrapup_save wrote those NULLs straight
-- over the lines code_flags_sync_week had put on the CPR row. Every wrap-up save erased that
-- person's flags for the week, and with them the Code Red's charge on their requirements.
--
-- Fix: code flags have one source (public.code_flags) and one writer onto the CPR row
-- (code_flags_sync_week). The wrap-up no longer takes or writes code reds or yellows.
--
-- Second gap in the same path: code_flags_sync_week does nothing when the week's CPR row does
-- not exist yet. That row appears with the first quote or check-in of the week (about 9:50 on
-- Monday this week), so a flag logged before then never reached the CPR. Now, whenever a CPR
-- week row is created, every flag already logged in that week is copied onto it.

-- 1) my_wrapup_save: the two code parameters are gone and the columns are not written.
DROP FUNCTION IF EXISTS public.my_wrapup_save(jsonb, text, text, date);

CREATE OR REPLACE FUNCTION public.my_wrapup_save(p_parts jsonb, p_week_ending date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  PERFORM public.require_login('staff');
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

  FOR i IN 1..jsonb_array_length(v_prompts) LOOP
    v_ans := COALESCE(btrim(p_parts ->> (i - 1)), '');
    IF v_ans = '' THEN v_all := false; END IF;
    v_text := v_text || i || '. ' || (v_prompts -> (i - 1) ->> 'title') || E'\n' || v_ans || E'\n\n';
  END LOOP;
  v_text := btrim(v_text);

  v_inbox := public.wrapup_inbox_cleared(v_me, v_today);

  -- Code Reds and Yellows are not part of the wrap-up. They come only from code_flags, and
  -- code_flags_sync_week is the only thing that writes them onto this row (Peter 2026-09-25).
  INSERT INTO public.weekly_cpr_team_detail
    (agency_id, weekly_cpr_report_id, team_member_id, wrapup_text, wrapup_done, inbox_done, updated_at)
  VALUES
    (v_agency, v_report, v_me, v_text, v_all, v_inbox, now())
  ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
  SET wrapup_text  = EXCLUDED.wrapup_text,
      wrapup_done  = EXCLUDED.wrapup_done,
      inbox_done   = EXCLUDED.inbox_done,
      updated_at   = now();

  RETURN jsonb_build_object('ok', true, 'week_ending', v_week_end, 'wrapup_done', v_all, 'inbox_done', v_inbox);
END;
$function$;

-- Same access the old version had: team logins and the server, nobody else.
REVOKE ALL ON FUNCTION public.my_wrapup_save(jsonb, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_wrapup_save(jsonb, date) TO authenticated, service_role;

-- 2) A new CPR week row picks up every flag already logged in that week.
CREATE OR REPLACE FUNCTION public.trg_weekly_cpr_reports_sync_code_flags()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tm uuid;
BEGIN
  FOR v_tm IN
    SELECT DISTINCT f.team_member_id
    FROM public.code_flags f
    WHERE f.agency_id = NEW.agency_id
      AND public.rp_week_end(f.flag_date) = NEW.week_ending_date
  LOOP
    -- A failed copy never blocks the CPR row. It leaves an alert instead.
    BEGIN
      PERFORM public.code_flags_sync_week(NEW.agency_id, v_tm, NEW.week_ending_date);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
      VALUES (NEW.agency_id, 'code_flag_sync_failed', 'warning',
              'Code flags did not reach the CPR',
              'A Code Red or Yellow for the week ending ' || to_char(NEW.week_ending_date, 'FMMon FMDD')
                || ' could not be copied onto that week''s CPR: ' || SQLERRM,
              'code_flags', NEW.id);
    END;
  END LOOP;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.trg_weekly_cpr_reports_sync_code_flags() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER trg_weekly_cpr_reports_sync_code_flags
AFTER INSERT ON public.weekly_cpr_reports
FOR EACH ROW EXECUTE FUNCTION public.trg_weekly_cpr_reports_sync_code_flags();

-- 3) Put back what the wrap-up saves erased. On 2026-09-25 the only flags on file are Cassie's
--    two for the week ending 2026-09-26, so that is the only row this touches.
SELECT public.code_flags_sync_week(w.agency_id, w.team_member_id, w.week_end)
FROM (
  SELECT DISTINCT f.agency_id, f.team_member_id, public.rp_week_end(f.flag_date) AS week_end
  FROM public.code_flags f
) w;
