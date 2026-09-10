-- Peter 2026-09-10, team channel follow-ups:
--  * The closing encouragement line is cut. Five pools of three lines meant a week with
--    the same shape kept drawing the same three lines, several times a day. The pace is
--    already shown by the check and down-arrow marks on the Quotes and Sales lines, so the
--    line only restated them. Repeated stock messages lose effect fast (advertising
--    wear-out, Pechmann & Stewart 1988), and generic feedback that is not tied to the task
--    often does nothing or hurts (Kluger & DeNisi 1996 meta-analysis). encouragement_text
--    stays in the return signature and is always NULL; both callers already skip NULL.
--  * Win-the-Week Quotes and Sales lines and the per-teammate call lines are bullets, to
--    match the per-person number lines. They used a two-space indent that did not read as
--    a list.

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.render_team_status_block(uuid,date,text,text,date)'::regprocedure)) <> 'c2d46f08a1d9d6062245cd1dfce2525d'
     OR md5(pg_get_functiondef('public.render_daily_calls_block(uuid,date)'::regprocedure)) <> 'e774b826d7aeb23de73abc580b9de106' THEN
    RAISE EXCEPTION 'render functions changed since this migration was written; re-read and rebuild';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.render_team_status_block(p_agency_id uuid, p_as_of_date date, p_fresh_type text, p_header_label text, p_wtw_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(block_text text, encouragement_text text, team_total_quotes numeric, team_total_sales numeric, fresh_count integer, carried_count integer, no_data_count integer, expected_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_wtw_date date; v_wtw_cycle record; v_wtw_week_start date;
  v_display_cycle record; v_display_week_start date;
  v_row record; v_text text := ''; v_ttq numeric := 0; v_tts numeric := 0;
  v_fresh int := 0; v_carried int := 0; v_nodata int := 0; v_expected int := 0;
  v_wtw record; v_q_pass boolean; v_sp_pass boolean;
  v_q_short int; v_sp_short numeric; v_carry_type_label text;
  v_display_quotes int; v_carry_label text;
  v_totals record; v_week_closed boolean;
BEGIN
  v_wtw_date := COALESCE(p_wtw_as_of_date, p_as_of_date);
  SELECT * INTO v_wtw_cycle FROM public.current_cycle_info(p_agency_id, v_wtw_date);
  v_wtw_week_start := v_wtw_cycle.week_ending_saturday - 6;

  SELECT * INTO v_display_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);
  v_display_week_start := v_display_cycle.week_ending_saturday - 6;

  v_week_closed := v_display_cycle.week_ending_saturday < v_wtw_cycle.week_ending_saturday
                   AND EXISTS (
                     SELECT 1 FROM public.weekly_cpr_reports r0
                     WHERE r0.agency_id = p_agency_id
                       AND r0.week_ending_date = v_display_cycle.week_ending_saturday
                       AND r0.won_the_week IS NOT NULL);

  -- Single newline: the blank line under the header was dead space (Peter 2026-09-10).
  v_text := p_header_label || E'\n';

  SELECT count(*) INTO v_expected
  FROM public.get_expected_teammates(p_agency_id, 'work_display', v_wtw_date);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name
      FROM public.get_expected_teammates(p_agency_id, 'work_display', v_wtw_date)
    ),
    current_period AS (
      SELECT tc.team_id, tc.quotes_week, tc.sales_points_quarter, tc.is_proxy_submission,
             sub.first_name AS submitted_by_first_name
      FROM public.team_checkins tc
      LEFT JOIN public.team sub ON sub.id = tc.submitted_by_team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = p_as_of_date
        AND tc.checkin_type = p_fresh_type
    ),
    carried AS (
      SELECT DISTINCT ON (tc.team_id)
        tc.team_id, tc.quotes_week, tc.sales_points_quarter,
        tc.checkin_date AS last_date, tc.checkin_type AS last_type,
        (tc.checkin_date < v_display_week_start) AS is_prior_week
      FROM public.team_checkins tc
      WHERE tc.agency_id = p_agency_id
        AND NOT (tc.checkin_date = p_as_of_date AND tc.checkin_type = p_fresh_type)
      ORDER BY tc.team_id, tc.received_at DESC
    ),
    cpr AS (
      SELECT d.team_member_id AS team_id, d.quotes_discussed, d.sales_points
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r1 ON r1.id = d.weekly_cpr_report_id
      WHERE r1.agency_id = p_agency_id
        AND r1.week_ending_date = v_display_cycle.week_ending_saturday
    )
    SELECT e.team_id, e.display_name, e.first_name,
      cd.team_id AS cpr_team_id, cd.quotes_discussed AS cpr_quotes, cd.sales_points AS cpr_sales,
      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,
      COALESCE(cp.is_proxy_submission, false) AS is_proxy_submission,
      cp.submitted_by_first_name,
      c.quotes_week AS carry_quotes, c.sales_points_quarter AS carry_sales,
      c.last_date, c.last_type, c.is_prior_week
    FROM expected e
    LEFT JOIN current_period cp ON cp.team_id = e.team_id
    LEFT JOIN carried c ON c.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(COALESCE(v_row.cpr_sales, 0), 'FM999G999G999') || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.cur_quotes IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_row.cur_quotes::text || '/'
        || to_char(COALESCE(v_row.cur_sales, 0), 'FM999G999G999');
      IF v_row.is_proxy_submission THEN
        v_text := v_text || ' (via ' || v_row.submitted_by_first_name || ')';
      END IF;
      v_text := v_text || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.carry_quotes IS NOT NULL THEN
      v_carry_type_label := CASE v_row.last_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_row.last_type) END;
      IF COALESCE(v_row.is_prior_week, false) THEN
        v_display_quotes := 0;
        v_carry_label := 'SP from ' || v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      ELSE
        v_display_quotes := v_row.carry_quotes;
        v_carry_label := v_carry_type_label || ' ' || to_char(v_row.last_date, 'Mon DD');
      END IF;
      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_display_quotes::text || '/'
        || to_char(COALESCE(v_row.carry_sales, 0), 'FM999G999G999')
        || ' (' || v_carry_label || ')' || E'\n';
      v_carried := v_carried + 1;
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0' || E'\n';
      v_nodata := v_nodata + 1;
    END IF;
  END LOOP;

  SELECT * INTO v_totals FROM public.get_team_checkin_totals(p_agency_id, v_wtw_week_start, v_wtw_cycle.week_ending_saturday);
  v_ttq := v_totals.total_quotes;

  SELECT COALESCE((
    SELECT quarterly_sales_points_qtd
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_wtw_cycle.week_ending_saturday
  ), 0) INTO v_tts;

  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, v_wtw_date);

  v_q_pass := v_ttq >= v_wtw.quotes_target_total;
  v_sp_pass := v_tts >= v_wtw.sp_target;
  v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_ttq::int);
  v_sp_short := GREATEST(0, v_wtw.sp_target - v_tts);

  -- Blank line BEFORE the section header stays. Blank line AFTER it is gone.
  v_text := v_text || E'\n📈 WtW ' || v_wtw.week_of_cycle
    || ' ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E'\n';
  v_text := v_text || '• Quotes: ' || v_ttq::text || '/' || v_wtw.quotes_target_total::text;
  IF v_q_pass THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || v_q_short::text; END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (+' || v_wtw.quotes_carryover::text || ' carryover)';
  END IF;
  v_text := v_text || E'\n';
  v_text := v_text || '• Sales: ' || to_char(v_tts, 'FM999G999G999')
    || '/' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_sp_pass THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || to_char(v_sp_short, 'FM999G999G999'); END IF;
  v_text := v_text || E'\n';

  -- Encouragement line cut 2026-09-10 (see migration header). Always NULL.
  RETURN QUERY SELECT v_text, NULL::text, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$function$;

CREATE OR REPLACE FUNCTION public.render_daily_calls_block(p_agency_id uuid, p_activity_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_out text := '';
  v_row record;
  v_row_count int := 0;
  v_missed int := 0;
BEGIN
  FOR v_row IN
    SELECT
      COALESCE(t.nickname, t.first_name) AS display_name,
      dca.inbound_calls_external,
      dca.outbound_calls_external,
      dca.inbound_talk_time_seconds + dca.outbound_talk_time_seconds AS talk_seconds
    FROM public.daily_call_activity dca
    JOIN public.team t ON t.id = dca.team_member_id
    WHERE dca.agency_id = p_agency_id
      AND dca.activity_date = p_activity_date
      AND dca.team_member_id IS NOT NULL
      AND t.is_admin_backoffice = false
    ORDER BY t.start_date NULLS LAST, t.first_name
  LOOP
    v_row_count := v_row_count + 1;
    v_out := v_out
      || format(
        E'• %s: %s/%s/%s min\n',
        v_row.display_name,
        v_row.inbound_calls_external,
        v_row.outbound_calls_external,
        v_row.talk_seconds / 60
      );
  END LOOP;

  IF v_row_count = 0 THEN
    RETURN '';
  END IF;

  SELECT COALESCE(SUM(abandoned_calls_external), 0) + COALESCE(SUM(voicemail_calls_external), 0)
  INTO v_missed
  FROM public.daily_call_activity
  WHERE agency_id = p_agency_id
    AND activity_date = p_activity_date
    AND team_member_id IS NULL;

  v_out :=
    format(E'📞 Calls %s (in/out/time)\n', to_char(p_activity_date, 'Mon DD'))
    || v_out;

  IF v_missed > 0 THEN
    v_out := v_out || format(E'• Missed: %s\n', v_missed);
  END IF;

  RETURN v_out;
END;
$function$;