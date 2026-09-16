-- One function computes sales points from Production. rp_week_scoreboard_for had this
-- aggregation inlined; get_sales_points_qtd was about to need the same thing. Rather than
-- a second copy, both call this. Auto apps count per VEHICLE; fire per policy; premium is
-- the issued figure where one exists; only rows with an issue date inside the cycle count.
CREATE OR REPLACE FUNCTION public.get_production_sales_points_qtd(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_member_id uuid, qtd_points numeric, prev_qtd_points numeric, pc_rate numeric, lh_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end date := public.rp_week_end(p_week_end);
  v_prev_end date := public.rp_week_end(p_week_end) - 7;
  v_cycle_start date;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);

  RETURN QUERY
  WITH prod AS (
    SELECT s.team_member_id AS tm, p.line_of_business AS lob,
           COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count,
           GREATEST(1, COALESCE(p.vehicle_count, s.vehicle_count, p.policy_count, 1)) AS auto_units,
           p.issued_date
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    WHERE s.agency_id = p_agency_id AND s.status = 'active'
      AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
  ),
  per AS (
    SELECT x.tm,
      public.compute_sp_from_production(
        COALESCE(SUM(CASE WHEN x.lob='auto'   THEN x.auto_units   END), 0),
        COALESCE(SUM(CASE WHEN x.lob='fire'   THEN x.policy_count END), 0),
        COALESCE(SUM(CASE WHEN x.lob='life'   THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='health' THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='auto'   THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='fire'   THEN x.premium      END), 0)) AS cur,
      public.compute_sp_from_production(
        COALESCE(SUM(CASE WHEN x.lob='auto'   AND x.issued_date <= v_prev_end THEN x.auto_units   END), 0),
        COALESCE(SUM(CASE WHEN x.lob='fire'   AND x.issued_date <= v_prev_end THEN x.policy_count END), 0),
        COALESCE(SUM(CASE WHEN x.lob='life'   AND x.issued_date <= v_prev_end THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='health' AND x.issued_date <= v_prev_end THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='auto'   AND x.issued_date <= v_prev_end THEN x.premium      END), 0),
        COALESCE(SUM(CASE WHEN x.lob='fire'   AND x.issued_date <= v_prev_end THEN x.premium      END), 0)) AS prev
    FROM prod x GROUP BY x.tm
  )
  SELECT per.tm,
         COALESCE((per.cur ->'commission'->>'total_commission')::numeric, 0),
         COALESCE((per.prev->'commission'->>'total_commission')::numeric, 0),
         (per.cur->'rates'->>'pc_rate_capped')::numeric,
         (per.cur->'rates'->>'lh_rate_capped')::numeric
  FROM per;
END $function$;
