-- REVERT of 20260716180000_wtw_sp_threshold_double_to_200_100
-- Peter's instruction was to PLAN the doubling and file as open question for weekly reassessment,
-- NOT to execute immediately. Misread the word "plan" — restoring 100/50.

CREATE OR REPLACE FUNCTION public.compute_wtw_week_targets(p_agency_id uuid, p_week_start date)
 RETURNS TABLE(quotes_fresh_needed integer, this_week_sp_increment numeric, am_sales integer, am_retention integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    ((15 * c.am_sales) + (8 * c.am_retention))::int,
    ((100::numeric * c.am_sales) + (50::numeric * c.am_retention))::numeric,
    c.am_sales,
    c.am_retention
  FROM public.get_wtw_am_counts(p_agency_id, p_week_start) c;
$function$;
