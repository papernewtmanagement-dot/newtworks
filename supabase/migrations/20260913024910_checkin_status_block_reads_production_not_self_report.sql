-- Peter 2026-09-11: the team check-in numbers come from Production (quote_log,
-- sales_log, retention_activity_log) instead of what people text in, and the
-- compiled message carries marketing points and retention points too.
-- Source is rp_week_scoreboard_for, the same function the Scoreboard tab uses, so
-- the Telegram message and the app can never disagree.
-- A closed week still reads the CPR snapshot, unchanged: Production logging only
-- starts the week of 2026-09-13, so older weeks have nothing to read.
-- Carry-forward is gone. Production is always current, so there is no such thing
-- as a stale row to carry.
CREATE OR REPLACE FUNCTION public.render_team_status_block(
  p_agency_id uuid, p_as_of_date date, p_fresh_type text, p_header_label text,
  p_wtw_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(block_text text, encouragement_text text, team_total_quotes numeric,
               team_total_sales numeric, fresh_count integer, carried_count integer,
               no_data_count integer, expected_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_wtw_date date; v_wtw_cycle record; v_wtw_week_start date;
  v_display_cycle record;
  v_row record; v_text text := ''; v_ttq numeric := 0; v_tts numeric := 0;
  v_fresh int := 0; v_carried int := 0; v_nodata int := 0; v_expected int := 0;
  v_wtw record; v_q_pass boolean; v_sp_pass boolean;
  v_q_short int; v_sp_short numeric;
  v_week_closed boolean;
  v_board jsonb; v_emoji text; v_extra text;
BEGIN
  v_wtw_date := COALESCE(p_wtw_as_of_date, p_as_of_date);
  SELECT * INTO v_wtw_cycle FROM public.current_cycle_info(p_agency_id, v_wtw_date);
  v_wtw_week_start := v_wtw_cycle.week_ending_saturday - 6;

  SELECT * INTO v_display_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);

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

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_display_cycle.week_ending_saturday);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name
      FROM public.get_expected_teammates(p_agency_id, 'work_display', v_wtw_date)
    ),
    board AS (
      SELECT (p->>'team_member_id')::uuid AS team_id,
             COALESCE((p->'quotes'->>'count')::numeric, 0)      AS quotes,
             COALESCE((p->'sales'->>'qtd_points')::numeric, 0)  AS sp_qtd,
             COALESCE((p->'sales'->>'points')::numeric, 0)      AS sp_week,
             COALESCE((p->'marketing'->>'points')::numeric, 0)  AS marketing,
             COALESCE((p->'retention'->>'net')::numeric, 0)     AS retention
      FROM jsonb_array_elements(v_board->'people') p
    ),
    cpr AS (
      SELECT d.team_member_id AS team_id, d.quotes_discussed, d.sales_points
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r1 ON r1.id = d.weekly_cpr_report_id
      WHERE r1.agency_id = p_agency_id
        AND r1.week_ending_date = v_display_cycle.week_ending_saturday
    )
    SELECT e.team_id, e.display_name,
      cd.team_id AS cpr_team_id, cd.quotes_discussed AS cpr_quotes, cd.sales_points AS cpr_sales,
      b.team_id AS board_team_id, b.quotes, b.sp_qtd, b.sp_week, b.marketing, b.retention
    FROM expected e
    LEFT JOIN board b ON b.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(COALESCE(v_row.cpr_sales, 0), 'FM999G999G999') || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.board_team_id IS NOT NULL THEN
      v_emoji := public.checkin_reaction_emoji(
        p_agency_id, v_row.team_id, v_row.quotes, p_as_of_date, p_fresh_type, v_row.sp_week);

      v_extra := '';
      IF v_row.marketing > 0 THEN
        v_extra := v_extra || ' · $' || to_char(v_row.marketing, 'FM999G999G990D00') || ' marketing';
      END IF;
      IF v_row.retention > 0 THEN
        v_extra := v_extra || ' · $' || to_char(v_row.retention, 'FM999G999G990D00') || ' retention';
      END IF;

      v_text := v_text || '• ' || v_row.display_name || ': '
        || v_row.quotes::text || '/'
        || to_char(v_row.sp_qtd, 'FM999G999G999')
        || ' ' || v_emoji || v_extra || E'\n';

      IF v_row.quotes > 0 OR v_row.sp_week > 0 OR v_row.marketing > 0 OR v_row.retention > 0 THEN
        v_fresh := v_fresh + 1;
      ELSE
        v_nodata := v_nodata + 1;
      END IF;
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0' || E'\n';
      v_nodata := v_nodata + 1;
    END IF;
  END LOOP;

  -- Team quote total for Win the Week comes from Production for the live week and
  -- from the check-in totals helper for a week that already closed.
  IF v_wtw_cycle.week_ending_saturday = v_display_cycle.week_ending_saturday THEN
    v_ttq := COALESCE((v_board->'team'->>'quotes')::numeric, 0);
  ELSE
    v_ttq := COALESCE((
      (public.rp_week_scoreboard_for(p_agency_id, v_wtw_cycle.week_ending_saturday))
        ->'team'->>'quotes')::numeric, 0);
  END IF;

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
    || ', ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E'\n';
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

  -- Encouragement line cut 2026-09-10. Always NULL.
  RETURN QUERY SELECT v_text, NULL::text, v_ttq, v_tts, v_fresh, v_carried, v_nodata, v_expected;
END;
$function$;
