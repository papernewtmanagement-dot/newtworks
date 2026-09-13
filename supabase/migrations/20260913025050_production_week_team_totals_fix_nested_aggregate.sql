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
  per_person AS (
    SELECT x.tm,
      COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.policy_count END), 0) AS auto_pol,
      COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.policy_count END), 0) AS fire_pol,
      COALESCE(SUM(CASE WHEN x.lob = 'life'   THEN x.premium END), 0)      AS life_prem,
      COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0)      AS health_prem,
      COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.premium END), 0)      AS auto_prem,
      COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.premium END), 0)      AS fire_prem
    FROM prod x GROUP BY x.tm
  ),
  sp AS (
    SELECT COALESCE(SUM(COALESCE((public.compute_sp_from_production(
             pp.auto_pol, pp.fire_pol, pp.life_prem, pp.health_prem, pp.auto_prem, pp.fire_prem
           )->'commission'->>'total_commission')::numeric, 0)), 0)::numeric AS points
    FROM per_person pp
  )
  SELECT q.quotes, sp.points FROM q CROSS JOIN sp;
END;
$function$;
