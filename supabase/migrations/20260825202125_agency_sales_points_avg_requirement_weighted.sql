-- agency_sales_points_avg_requirement_weighted
-- Peter ruling 2026-08-25: admin and Account Associates never carry a Sales Points
-- requirement, so they are not part of the agency-wide average's denominator. Admin
-- production DOES count toward fulfillment. Retention Account/Unit Managers carry HALF
-- the requirement, matching the long-standing Win-the-Week personal minimums in
-- get_weekly_cpr_requirements (Sales 15 quotes / Retention 8).
--
-- Shape: fulfillment total (every agency seat's weekly Sales Points, Owner included)
-- divided by requirement-weighted headcount (Sales AM/UM 1.0, Retention AM/UM 0.5).
-- Result stays comparable to sales_points_band_config, which is a per-full-requirement
-- weekly figure. Straight AVG() over people was the prior behaviour and put a zero in
-- for every seat that never had a requirement.
CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(p_agency_id uuid, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH seats AS (
    SELECT
      t.id,
      CASE
        WHEN t.role_level IN ('Account Manager','Unit Manager','Section Manager','Office Manager')
             AND t.role_category = 'Sales'     THEN 1.0
        WHEN t.role_level IN ('Account Manager','Unit Manager','Section Manager','Office Manager')
             AND t.role_category = 'Retention' THEN 0.5
        ELSE 0
      END AS requirement_weight
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.is_active
      AND t.category = 'agency'
      AND COALESCE(t.is_test_user, false) = false
      AND COALESCE(t.is_admin_backoffice, false) = false
  ),
  totals AS (
    SELECT
      SUM(COALESCE(public.team_member_sales_points_avg_nwk(s.id, 13, p_end_date), 0)) AS fulfillment,
      SUM(s.requirement_weight)                                                        AS requirement
    FROM seats s
  )
  SELECT CASE WHEN COALESCE(requirement, 0) = 0 THEN NULL
              ELSE ROUND(fulfillment / requirement, 2) END
  FROM totals;
$function$;
