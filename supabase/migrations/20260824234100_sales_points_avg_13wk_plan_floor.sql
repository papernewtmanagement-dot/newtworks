-- sales_points_avg_13wk_plan_floor
-- DESIGN RECORD: the 13-week rolling Sales Points average (per person and agency-wide)
-- must never read weekly_cpr_team_detail rows dated before the residual-pool plan's
-- first scheduled week (MIN(team_comp_pool_schedule.week_end_date), currently 2026-07-11).
-- Rows before that week carry Sales Points on the OLD scale (pre-rescale QTD values,
-- e.g. 5,179 for one producer on 2026-06-27). Inside the 91-day window that one row was
-- counted as a single-week delta and inflated the average ~5x (781/wk vs ~153/wk real),
-- which mis-rated producers as Elite and feeds the PTO / 4-day-week gate and the pay ladder.
-- Floor is read from the schedule table, not hard-coded, so it needs no follow-up edit.
-- Found 2026-08-24 while designing the Sales Points pay ladder.

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_13wk(p_team_member_id uuid, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH plan_floor AS (
    SELECT COALESCE(MIN(s.week_end_date), DATE '1900-01-01') AS first_week
    FROM public.team t
    JOIN public.team_comp_pool_schedule s ON s.agency_id = t.agency_id
    WHERE t.id = p_team_member_id
  ),
  window_rows AS (
    SELECT
      r.week_ending_date,
      td.sales_points AS qtd_value,
      make_date(
        EXTRACT(year FROM r.week_ending_date)::int,
        ((EXTRACT(month FROM r.week_ending_date)::int - 1) / 3) * 3 + 1,
        1
      ) AS quarter_start
    FROM public.weekly_cpr_team_detail td
    JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
    CROSS JOIN plan_floor pf
    WHERE td.team_member_id = p_team_member_id
      AND r.week_ending_date <= p_end_date
      AND r.week_ending_date >  p_end_date - INTERVAL '91 days'
      AND r.week_ending_date >= pf.first_week
      AND td.sales_points IS NOT NULL
  ),
  with_deltas AS (
    SELECT
      w.qtd_value - COALESCE(
        (SELECT td2.sales_points
         FROM public.weekly_cpr_team_detail td2
         JOIN public.weekly_cpr_reports r2 ON r2.id = td2.weekly_cpr_report_id
         CROSS JOIN plan_floor pf2
         WHERE td2.team_member_id = p_team_member_id
           AND r2.week_ending_date <  w.week_ending_date
           AND r2.week_ending_date >= GREATEST(w.quarter_start, pf2.first_week)
           AND td2.sales_points IS NOT NULL
         ORDER BY r2.week_ending_date DESC
         LIMIT 1),
        0
      ) AS weekly_delta
    FROM window_rows w
  )
  SELECT AVG(weekly_delta)::numeric FROM with_deltas;
$function$
;

CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(p_agency_id uuid, p_end_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH plan_floor AS (
    SELECT COALESCE(MIN(s.week_end_date), DATE '1900-01-01') AS first_week
    FROM public.team_comp_pool_schedule s
    WHERE s.agency_id = p_agency_id
  ),
  window_rows AS (
    SELECT
      td.team_member_id,
      r.week_ending_date,
      td.sales_points AS qtd_value,
      make_date(
        EXTRACT(year FROM r.week_ending_date)::int,
        ((EXTRACT(month FROM r.week_ending_date)::int - 1) / 3) * 3 + 1,
        1
      ) AS quarter_start
    FROM public.weekly_cpr_team_detail td
    JOIN public.weekly_cpr_reports r ON r.id = td.weekly_cpr_report_id
    CROSS JOIN plan_floor pf
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date <= p_end_date
      AND r.week_ending_date >  p_end_date - INTERVAL '91 days'
      AND r.week_ending_date >= pf.first_week
      AND td.sales_points IS NOT NULL
  ),
  with_deltas AS (
    SELECT
      w.qtd_value - COALESCE(
        (SELECT td2.sales_points
         FROM public.weekly_cpr_team_detail td2
         JOIN public.weekly_cpr_reports r2 ON r2.id = td2.weekly_cpr_report_id
         CROSS JOIN plan_floor pf2
         WHERE r2.agency_id           = p_agency_id
           AND td2.team_member_id     = w.team_member_id
           AND r2.week_ending_date <  w.week_ending_date
           AND r2.week_ending_date >= GREATEST(w.quarter_start, pf2.first_week)
           AND td2.sales_points IS NOT NULL
         ORDER BY r2.week_ending_date DESC
         LIMIT 1),
        0
      ) AS weekly_delta
    FROM window_rows w
  )
  SELECT AVG(weekly_delta)::numeric FROM with_deltas;
$function$
;
