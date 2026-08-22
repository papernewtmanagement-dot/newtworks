-- Double WtW SP threshold: AM-Sales 100→200, AM-Retention 50→100
-- Quotes unchanged (15/8). Ratio locked at 2:1.
-- Rationale: Under $100/$50 (rescaled 2026-07-06), Week 1 of current cycle cleared at 131% SP,
-- Week 2 mid-week already at 149% cumulative. John Kostov alone producing ~$250/wk SP.
-- Doubling to test if it creates real coaching pressure for Tommy + Stephanie.
-- Filed as open_question for weekly reassessment (see open_questions row).

CREATE OR REPLACE FUNCTION public.compute_wtw_week_targets(p_agency_id uuid, p_week_start date)
 RETURNS TABLE(quotes_fresh_needed integer, this_week_sp_increment numeric, am_sales integer, am_retention integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    ((15 * c.am_sales) + (8 * c.am_retention))::int,
    ((200::numeric * c.am_sales) + (100::numeric * c.am_retention))::numeric,
    c.am_sales,
    c.am_retention
  FROM public.get_wtw_am_counts(p_agency_id, p_week_start) c;
$function$;
