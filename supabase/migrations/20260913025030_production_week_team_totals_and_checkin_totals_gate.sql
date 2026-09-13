-- Team quote and sales-point totals straight from Production, for Win the Week.
-- Lean on purpose: the Scoreboard function builds every item list as well, and
-- this runs on every CPR page load. Same maths, same roster, no item arrays.
CREATE OR REPLACE FUNCTION public.production_week_team_totals(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(total_quotes numeric, total_sales_points numeric)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
  v_cycle_start date;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);

  RETURN QUERY
  WITH roster AS (
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  q AS (
    SELECT COALESCE(SUM(n), 0)::numeric AS quotes FROM (
      SELECT count(DISTINCT ql.customer_label || COALESCE(ql.phone_last4, ''))::int AS n
      FROM public.quote_log ql
      JOIN roster r ON r.id = ql.team_member_id
      WHERE ql.agency_id = p_agency_id AND ql.status = 'active' AND ql.week_end_date = v_week_end
      GROUP BY ql.team_member_id
    ) x
  ),
  prod AS (
    SELECT s.team_member_id AS tm, p.line_of_business AS lob,
           COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    JOIN roster r ON r.id = s.team_member_id
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
  ),
  sp AS (
    SELECT COALESCE(SUM(
      COALESCE((public.compute_sp_from_production(
        COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.policy_count END), 0),
        COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.policy_count END), 0),
        COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),
        COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
        COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),
        COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0)
      )->'commission'->>'total_commission')::numeric, 0)
    ), 0)::numeric AS points
    FROM prod x GROUP BY x.tm
  ),
  sp_total AS (SELECT COALESCE(SUM(points), 0)::numeric AS points FROM sp)
  SELECT q.quotes, sp_total.points FROM q CROSS JOIN sp_total;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.production_week_team_totals(uuid, date) TO anon, authenticated, service_role;

-- Peter 2026-09-11: check-in numbers come from Production, not self-report.
-- From the Retention Points go-live week (settings.retention_points_go_live_week_end)
-- the Win the Week totals read Production. Every earlier week keeps reading the
-- texted-in check-ins exactly as before, so no closed week and no past pay moves.
CREATE OR REPLACE FUNCTION public.get_team_checkin_totals(p_agency_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(total_quotes numeric, total_sales_points numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_go_live date;
BEGIN
  SELECT NULLIF(setting_value, '')::date INTO v_go_live
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'retention_points_go_live_week_end';

  IF v_go_live IS NOT NULL AND p_period_end >= v_go_live THEN
    RETURN QUERY SELECT t.total_quotes, t.total_sales_points
    FROM public.production_week_team_totals(p_agency_id, p_period_end) t;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    COALESCE(SUM(latest_q), 0)  AS total_quotes,
    COALESCE(SUM(latest_sp), 0) AS total_sales_points
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.quotes_week AS latest_q,
      tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN p_period_start AND p_period_end
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;
END;
$function$;
