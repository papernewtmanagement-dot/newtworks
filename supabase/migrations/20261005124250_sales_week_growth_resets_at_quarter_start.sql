CREATE OR REPLACE FUNCTION public.rp_sales_week_growth(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_member_id uuid, qtd numeric, prev numeric, growth numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- 2026-10-05: the first week of a new quarter has no prior week inside the quarter, so the
  -- week's growth is the quarter to date itself. It used to subtract last quarter's final
  -- total, and every Scoreboard name showed a big drop the week sales points reset.
  WITH wk AS (SELECT public.rp_week_end(p_week_end) AS this_end,
                     (SELECT c.cycle_start FROM public.current_cycle_info(p_agency_id, public.rp_week_end(p_week_end)) c) AS cyc_start),
  cur AS (SELECT x.team_id, x.sales_points
          FROM wk, public.get_sales_points_qtd(p_agency_id, wk.this_end) x),
  pri AS (SELECT x.team_id, x.sales_points
          FROM wk, public.get_sales_points_qtd(p_agency_id, wk.this_end - 7) x
          WHERE wk.cyc_start IS NULL OR wk.this_end - 7 >= wk.cyc_start)
  SELECT COALESCE(c.team_id, p.team_id) AS team_member_id,
         COALESCE(c.sales_points, 0) AS qtd,
         COALESCE(p.sales_points, 0) AS prev,
         ROUND(COALESCE(c.sales_points, 0) - COALESCE(p.sales_points, 0), 2) AS growth
  FROM cur c FULL JOIN pri p ON p.team_id = c.team_id;
$function$;
