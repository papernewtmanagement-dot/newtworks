-- Win-the-Week required quotes + required sales points were counting a teammate who left
-- mid-week as a FULL seat for that whole week. get_wtw_am_counts returns whole-person counts
-- and compute_wtw_week_targets multiplied 15/8 quotes and 100/50 sales points by those whole
-- numbers, so the week someone is terminated still demanded a full week of production from
-- a seat that only existed for part of it.
--
-- Fix: a new seat-weight function that gives each seat the fraction of that week's Monday-to-
-- Friday workdays the person was still employed (end_date is their last day, inclusive).
-- Nobody employed for the whole week is affected - their weight is 1. Anyone already gone
-- before the week started is filtered out upstream by get_expected_teammates, weight 0.
--
-- Workdays Monday-Friday is the same 5-day basis the pace curve in render_team_status_block
-- already uses, so the requirement and the pace line agree.
--
-- Quotes and sales points a departing teammate actually contributed are untouched: those come
-- from get_team_checkin_totals and get_cpr_detail_sales_points_qtd, neither of which filters on
-- the roster. Only the REQUIREMENT side is prorated.
--
-- get_wtw_am_counts keeps returning whole-person headcounts - that is what it is named for and
-- what display surfaces read. Only the targets are weighted.

CREATE OR REPLACE FUNCTION public.get_wtw_am_seat_weights(p_agency_id uuid, p_week_start date)
 RETURNS TABLE(am_sales_weight numeric, am_retention_weight numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  WITH bounds AS (
    SELECT (p_week_start - EXTRACT(dow FROM p_week_start)::int)::date AS sunday
  ),
  days AS (
    SELECT (b.sunday + 1)::date AS monday, (b.sunday + 5)::date AS friday FROM bounds b
  ),
  seats AS (
    SELECT 'sales'::text AS bucket, e.team_id
      FROM public.get_expected_teammates(p_agency_id, 'wtw_am_sales', p_week_start) e
    UNION ALL
    SELECT 'retention'::text AS bucket, e.team_id
      FROM public.get_expected_teammates(p_agency_id, 'wtw_am_retention', p_week_start) e
  ),
  weighted AS (
    SELECT
      s.bucket,
      CASE
        WHEN t.end_date IS NULL THEN 1.0::numeric
        ELSE LEAST(5, GREATEST(0, (LEAST(t.end_date, d.friday) - d.monday) + 1))::numeric / 5.0
      END AS w
    FROM seats s
    JOIN public.team t ON t.id = s.team_id
    CROSS JOIN days d
  )
  SELECT
    COALESCE(SUM(w.w) FILTER (WHERE w.bucket = 'sales'), 0)::numeric,
    COALESCE(SUM(w.w) FILTER (WHERE w.bucket = 'retention'), 0)::numeric
  FROM weighted w;
$function$;

COMMENT ON FUNCTION public.get_wtw_am_seat_weights(uuid, date) IS
'Win-the-Week seat weights for one week. Each Account Manager / Unit Manager seat counts as the fraction of that week''s Monday-Friday workdays the person was still employed (team.end_date is the last day worked, inclusive). Full-week people weigh 1. Someone terminated on the Monday weighs 0.20. Used only for the REQUIREMENT side (quotes needed, sales points needed) - what a departing teammate actually produced still counts in full, from get_team_checkin_totals and get_cpr_detail_sales_points_qtd. Whole-person headcounts stay in get_wtw_am_counts.';

CREATE OR REPLACE FUNCTION public.compute_wtw_week_targets(p_agency_id uuid, p_week_start date)
 RETURNS TABLE(quotes_fresh_needed integer, this_week_sp_increment numeric, am_sales integer, am_retention integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    ROUND((15::numeric * w.am_sales_weight) + (8::numeric * w.am_retention_weight))::int,
    ROUND((100::numeric * w.am_sales_weight) + (50::numeric * w.am_retention_weight), 2)::numeric,
    c.am_sales,
    c.am_retention
  FROM public.get_wtw_am_counts(p_agency_id, p_week_start) c
  CROSS JOIN public.get_wtw_am_seat_weights(p_agency_id, p_week_start) w;
$function$;

COMMENT ON FUNCTION public.compute_wtw_week_targets(uuid, date) IS
'Win-the-Week targets for one week. Quotes needed and sales points needed are weighted by get_wtw_am_seat_weights, so a seat that only existed for part of the week is only asked for that part (added 2026-09-02 after a mid-week termination demanded a full week from a seat that ended on the Monday). am_sales and am_retention stay whole-person headcounts for display.';
