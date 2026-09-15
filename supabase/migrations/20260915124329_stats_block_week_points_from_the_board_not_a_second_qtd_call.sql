-- The stats block worked this week's sales points out by pulling the whole
-- quarter twice, once for this week and once for last week, and subtracting.
-- The scoreboard already returns this week's points, so it now reads that and
-- the second quarter-to-date pull is gone. One place does the subtraction.
-- Quarter-to-date still comes from get_sales_points_qtd, which is the one
-- source, and which now reads Production for live weeks.
CREATE OR REPLACE FUNCTION public.render_team_stats_block(p_agency_id uuid, p_display_date date, p_fresh_type text)
 RETURNS TABLE(block_text text, expected_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_today_real date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_display_cycle record; v_current_cycle record;
  v_week_closed boolean; v_board jsonb; v_row record; v_emoji text;
  v_text text; v_expected int := 0;
BEGIN
  SELECT * INTO v_display_cycle FROM public.current_cycle_info(p_agency_id, p_display_date);
  SELECT * INTO v_current_cycle FROM public.current_cycle_info(p_agency_id, v_today_real);

  v_week_closed := v_display_cycle.week_ending_saturday < v_current_cycle.week_ending_saturday
                   AND EXISTS (SELECT 1 FROM public.weekly_cpr_reports r
                               WHERE r.agency_id = p_agency_id
                                 AND r.week_ending_date = v_display_cycle.week_ending_saturday
                                 AND r.won_the_week IS NOT NULL);

  v_text := '📊 Stats (MP/' || public.lbl_quotes() || '/SP/RP)' || E'\n';

  SELECT count(*) INTO v_expected
  FROM public.get_expected_teammates(p_agency_id, 'work_display', p_display_date);

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_display_cycle.week_ending_saturday);

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, display_name, first_name, start_date, role_level
      FROM public.get_expected_teammates(p_agency_id, 'work_display', p_display_date)
    ),
    board AS (
      SELECT (p->>'team_member_id')::uuid AS team_id,
             COALESCE((p->'quotes'->>'count')::numeric, 0)     AS quotes,
             COALESCE((p->'marketing'->>'points')::numeric, 0) AS marketing,
             COALESCE((p->'retention'->>'net')::numeric, 0)    AS retention,
             COALESCE((p->'sales'->>'points')::numeric, 0)     AS sp_week
      FROM jsonb_array_elements(v_board->'people') p
    ),
    spq AS (
      SELECT s.team_id, s.sales_points AS sp_qtd
      FROM public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday) s
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
      COALESCE(sq.sp_qtd, 0) AS sp_qtd, COALESCE(b.sp_week, 0) AS sp_week
    FROM expected e
    LEFT JOIN board b ON b.team_id = e.team_id
    LEFT JOIN spq sq ON sq.team_id = e.team_id
    LEFT JOIN cpr cd ON cd.team_id = e.team_id
    ORDER BY public.role_level_rank(e.role_level), e.start_date NULLS LAST, e.first_name
  LOOP
    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN
      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(COALESCE(v_row.marketing, 0)), 'FM999G999G999') || '/'
        || COALESCE(v_row.cpr_quotes, 0)::text || '/'
        || to_char(floor(COALESCE(v_row.cpr_sales, 0)), 'FM999G999G999') || '/'
        || to_char(floor(COALESCE(v_row.retention, 0)), 'FM999G999G999') || E'\n';
    ELSIF v_row.board_team_id IS NOT NULL THEN
      v_emoji := public.checkin_reaction_emoji(
        p_agency_id, v_row.team_id, v_row.quotes, p_display_date, p_fresh_type, v_row.sp_week);
      v_text := v_text || '• ' || v_row.display_name || ': '
        || to_char(floor(v_row.marketing), 'FM999G999G999') || '/'
        || v_row.quotes::text || '/'
        || to_char(floor(v_row.sp_qtd), 'FM999G999G999') || '/'
        || to_char(floor(v_row.retention), 'FM999G999G999')
        || COALESCE(' ' || v_emoji, '') || E'\n';
    ELSE
      v_text := v_text || '• ' || v_row.display_name || ': 0/0/0/0' || E'\n';
    END IF;
  END LOOP;

  RETURN QUERY SELECT rtrim(v_text, E'\n'), v_expected;
END;
$function$;
