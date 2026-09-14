-- Per-person line is now four point figures in one fixed order, slash separated,
-- each rounded DOWN to a whole point (Peter 2026-09-14):
--   marketing / week quotes / sales points / retention points
-- The key rides on the header instead of repeating a word on every row, and the
-- dollar signs are gone -- these are points, not dollars. Zero shows as 0 rather
-- than dropping out, so every row has the same four slots in the same places and
-- can be read down the column. Closed-week rows keep their frozen CPR quotes and
-- sales points and pick marketing and retention up from that week's scoreboard,
-- so the format does not change shape mid-week.
CREATE OR REPLACE FUNCTION public.render_team_status_block(p_agency_id uuid, p_as_of_date date, p_fresh_type text, p_header_label text, p_wtw_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(block_text text, encouragement_text text, team_total_quotes numeric, team_total_sales numeric, fresh_count integer, carried_count integer, no_data_count integer, expected_count integer)
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
  v_board jsonb; v_emoji text;
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
  -- The column key sits on the header line (Peter 2026-09-14).
  v_text := p_header_label || ' (MP/Quotes/SP/RP)' || E'\n';

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

             COALESCE((p->'marketing'->>'points')::numeric, 0)  AS marketing,
             COALESCE((p->'retention'->>'net')::numeric, 0)     AS retention
      FROM jsonb_array_elements(v_board->'people') p
    ),
    spq AS (
      SELECT s.team_id, s.sales_points AS sp_qtd,
             GREATEST(0, s.sales_points - COALESCE(pv.sales_points, 0)) AS sp_week
      FROM public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday) s
      LEFT JOIN public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday - 7) pv
        ON pv.team_id = s.team_id
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
      b.team_id AS board_team_id, b.quotes, b.marketing, b.retention,
      COALESCE(sq.sp_qtd, 0) AS sp_qtd, COALESCE(sq.sp_week, 0) AS sp_week
    FROM expected e
    LEFT JOIN board b ON b.team_id = e.team_id
    LEFT JOIN spq sq ON sq.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(COALESCE(v_row.marketing, 0)), 'FM999G999G999') || '/'
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(floor(COALESCE(v_row.cpr_sales, 0)), 'FM999G999G999') || '/'
        || to_char(floor(COALESCE(v_row.retention, 0)), 'FM999G999G999') || E'\n';
      v_fresh := v_fresh + 1;
    ELSIF v_row.board_team_id IS NOT NULL THEN
      v_emoji := public.checkin_reaction_emoji(
        p_agency_id, v_row.team_id, v_row.quotes, p_as_of_date, p_fresh_type, v_row.sp_week);

      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(v_row.marketing), 'FM999G999G999') || '/'
        || v_row.quotes::text || '/'
        || to_char(floor(v_row.sp_qtd), 'FM999G999G999') || '/'
        || to_char(floor(v_row.retention), 'FM999G999G999')
        || COALESCE(' ' || v_emoji, '') || E'\n';

      IF v_row.quotes > 0 OR v_row.sp_week > 0 OR v_row.marketing > 0 OR v_row.retention > 0 THEN
        v_fresh := v_fresh + 1;
      ELSE
        v_nodata := v_nodata + 1;
      END IF;
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0/0/0' || E'\n';
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