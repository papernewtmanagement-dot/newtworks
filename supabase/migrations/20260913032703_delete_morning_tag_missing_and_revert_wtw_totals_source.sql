-- 1. Morning Tag Missing deleted for good (Peter 2026-09-12). Run-log rows first,
--    they carry a foreign key to the recipe.
DELETE FROM public.automation_run_log WHERE recipe_id = 'dd0a0734-fd43-466c-bc10-6d8ff88877bb';
DELETE FROM public.automation_recipes WHERE id = 'dd0a0734-fd43-466c-bc10-6d8ff88877bb';

-- 2. Win the Week totals go back to exactly what they were. My replacement summed
--    sales points per person, which is not how the agency figure is built, and it
--    dropped anyone off the current roster. Both wrong. Nothing about Win the Week
--    or pay changes until Peter rules on the sales-point source.
CREATE OR REPLACE FUNCTION public.get_team_checkin_totals(p_agency_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(total_quotes numeric, total_sales_points numeric)
 LANGUAGE sql
 STABLE
AS $function$
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
$function$;

DROP FUNCTION IF EXISTS public.production_week_team_totals(uuid, date);
