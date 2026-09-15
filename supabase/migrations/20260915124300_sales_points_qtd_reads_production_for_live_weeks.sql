-- Sales points have one source: get_sales_points_qtd. Production now goes INSIDE
-- it, which is where the standing rule says it belongs, rather than callers
-- reaching past it to the scoreboard.
-- Order of sources, highest first:
--   1. Production, for any week the scoreboard runs live (after 2026-09-12).
--   2. The manual override on the weekly CPR team detail rows.
--   3. The old self-reported figure from the Telegram check-ins.
-- Weeks on or before 2026-09-12 are untouched: the scoreboard returns reported
-- mode for those, so the override still wins and every historical number holds.
-- Someone who has left keeps their last figure. They are not on a live board, so
-- they fall through to the override, exactly as before.
CREATE OR REPLACE FUNCTION public.get_sales_points_qtd(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_id uuid, sales_points numeric, source text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_end date;
  v_cycle_start date;
  v_board jsonb;
  v_live boolean;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_week_end);
  v_live := (v_board->>'mode') = 'live';

  RETURN QUERY
  WITH production AS (
    SELECT (p->>'team_member_id')::uuid AS tm,
           (p->'sales'->>'qtd_points')::numeric AS pts
    FROM jsonb_array_elements(COALESCE(v_board->'people', '[]'::jsonb)) p
    WHERE v_live AND p->'sales'->>'qtd_points' IS NOT NULL
  ),
  override AS (
    SELECT DISTINCT ON (d.team_member_id)
      d.team_member_id AS tm, d.sales_points AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
      AND d.sales_points IS NOT NULL
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  reported AS (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id AS tm, tc.sales_points_quarter AS pts
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle_start AND v_week_end
      AND tc.sales_points_quarter IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ),
  everyone AS (
    SELECT tm FROM production
    UNION SELECT tm FROM override
    UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(pr.pts, o.pts, rp.pts, 0)::numeric,
         CASE WHEN pr.pts IS NOT NULL THEN 'production'
              WHEN o.pts IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN production pr ON pr.tm = e.tm
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$function$;
