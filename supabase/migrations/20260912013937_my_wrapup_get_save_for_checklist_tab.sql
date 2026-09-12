-- Checklist tab: a teammate writes their own weekly wrap-up straight into the
-- CPR record instead of emailing it. Same six requirements as the processes
-- manual (op-rule "Weekly wrap-up email requirements"), same stored text shape
-- the email parser already writes, so CPRDetail reads it unchanged.
--
-- The email path (wrapup_ingest + llm-queue-drainer) keeps working; its own
-- staleness guard refuses to overwrite text that changed after it queued, so a
-- teammate typing here can never be clobbered by a late email job.

CREATE OR REPLACE FUNCTION public.my_wrapup_prompts()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_build_array(
    jsonb_build_object('n', 1, 'title', 'Personal life & annuity status updates',        'hint', 'Your book, pending apps, upcoming reviews.'),
    jsonb_build_object('n', 2, 'title', 'Lapse/cancel trends + individual highlights',   'hint', 'Trends you are seeing, and specific wins.'),
    jsonb_build_object('n', 3, 'title', 'Personal obstacles + solutions',                'hint', 'What is in your way, and what you propose.'),
    jsonb_build_object('n', 4, 'title', 'Plan for a 1% increase in sales points next week', 'hint', 'What you will do differently.'),
    jsonb_build_object('n', 5, 'title', 'Efficiency / pain-point recommendation',        'hint', 'One thing that would make the office run better.'),
    jsonb_build_object('n', 6, 'title', 'Brags on teammates',                            'hint', 'Something you saw that matched our mission or their job description.')
  );
$function$;

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
    'prompts', public.my_wrapup_prompts()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.my_wrapup_save(
  p_parts jsonb,
  p_inbox_done boolean DEFAULT NULL,
  p_code_reds text DEFAULT NULL,
  p_code_yellows text DEFAULT NULL,
  p_week_ending date DEFAULT NULL
)
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

  INSERT INTO public.weekly_cpr_team_detail
    (agency_id, weekly_cpr_report_id, team_member_id, wrapup_text, wrapup_done, inbox_done, code_reds, code_yellows, updated_at)
  VALUES
    (v_agency, v_report, v_me, v_text, v_all, p_inbox_done, p_code_reds, p_code_yellows, now())
  ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
  SET wrapup_text  = EXCLUDED.wrapup_text,
      wrapup_done  = EXCLUDED.wrapup_done,
      inbox_done   = COALESCE(EXCLUDED.inbox_done, public.weekly_cpr_team_detail.inbox_done),
      code_reds    = EXCLUDED.code_reds,
      code_yellows = EXCLUDED.code_yellows,
      updated_at   = now();

  RETURN jsonb_build_object('ok', true, 'week_ending', v_week_end, 'wrapup_done', v_all);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.my_wrapup_prompts() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.my_wrapup_get(date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.my_wrapup_save(jsonb, boolean, text, text, date) TO authenticated, service_role;