-- Adds a 'units' block to the sp jsonb so callers can show WHAT produced each tier
-- (70 auto vehicles -> 11 steps) without recomputing anything. Purely additive:
-- every existing key in the jsonb is unchanged.
CREATE OR REPLACE FUNCTION public.production_sales_points_for(p_agency_id uuid, p_from date, p_through date)
 RETURNS TABLE(team_member_id uuid, sp jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH agg AS (
    SELECT x.tm,
           COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.units   END), 0) AS auto_apps,
           COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.units   END), 0) AS fire_apps,
           COALESCE(SUM(CASE WHEN x.lob = 'life'   THEN x.premium END), 0) AS life_prem,
           COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0) AS health_prem,
           COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.premium END), 0) AS auto_prem,
           COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.premium END), 0) AS fire_prem,
           COALESCE(SUM(CASE WHEN x.lob = 'life'   THEN x.units   END), 0) AS life_apps,
           COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.units   END), 0) AS health_apps
    FROM public.production_rows_for(p_agency_id, p_from, p_through) x
    GROUP BY x.tm
  )
  SELECT a.tm,
         public.compute_sp_from_production(a.auto_apps, a.fire_apps, a.life_prem,
                                           a.health_prem, a.auto_prem, a.fire_prem)
         || jsonb_build_object('units', jsonb_build_object(
              'auto_apps',    a.auto_apps,
              'fire_apps',    a.fire_apps,
              'life_apps',    a.life_apps,
              'health_apps',  a.health_apps,
              'auto_premium', a.auto_prem,
              'fire_premium', a.fire_prem,
              'life_premium', a.life_prem,
              'health_premium', a.health_prem))
  FROM agg a;
$function$;
