CREATE OR REPLACE FUNCTION public.my_wrapup_finish(p_on boolean DEFAULT true, p_week_ending date DEFAULT NULL::date)
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
  v_at timestamptz;
  v_done boolean;
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

  -- Peter 2026-09-21: nobody closes their week until every wrap-up answer is in.
  -- wrapup_done is the one answer to "is it done" (written by my_wrapup_save).
  IF COALESCE(p_on, true) THEN
    SELECT d.wrapup_done INTO v_done
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report AND d.team_member_id = v_me;
    IF NOT COALESCE(v_done, false) THEN
      RAISE EXCEPTION 'Answer all % wrap-up questions before you close your week.',
        jsonb_array_length(public.my_wrapup_prompts()) USING ERRCODE = '22023';
    END IF;
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
$function$;
