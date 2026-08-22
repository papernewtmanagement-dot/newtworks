-- Rewrite the two 13-wk rolling-avg SP functions to compute weekly deltas from QTD-cumulative
-- stored values, then average the deltas. Prior simple AVG(sales_points) biased toward
-- end-of-quarter rows (each row includes all prior quarter weeks' SP).
--
-- Delta logic per row in window:
--   weekly_delta = current_row.sales_points 
--                - most_recent_prior_saturday_in_same_quarter_for_same_person.sales_points
--   If no prior row in same quarter → delta = current value (first Sat of quarter)

CREATE OR REPLACE FUNCTION public.team_member_sales_points_avg_13wk(
  p_team_member_id uuid,
  p_end_date date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH window_rows AS (
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
    WHERE td.team_member_id = p_team_member_id
      AND r.week_ending_date <= p_end_date
      AND r.week_ending_date >  p_end_date - INTERVAL '91 days'
      AND td.sales_points IS NOT NULL
  ),
  with_deltas AS (
    SELECT
      w.qtd_value - COALESCE(
        (SELECT td2.sales_points
         FROM public.weekly_cpr_team_detail td2
         JOIN public.weekly_cpr_reports r2 ON r2.id = td2.weekly_cpr_report_id
         WHERE td2.team_member_id = p_team_member_id
           AND r2.week_ending_date <  w.week_ending_date
           AND r2.week_ending_date >= w.quarter_start
           AND td2.sales_points IS NOT NULL
         ORDER BY r2.week_ending_date DESC
         LIMIT 1),
        0
      ) AS weekly_delta
    FROM window_rows w
  )
  SELECT AVG(weekly_delta)::numeric FROM with_deltas;
$function$;

CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(
  p_agency_id uuid,
  p_end_date date DEFAULT CURRENT_DATE
)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  WITH window_rows AS (
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
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date <= p_end_date
      AND r.week_ending_date >  p_end_date - INTERVAL '91 days'
      AND td.sales_points IS NOT NULL
  ),
  with_deltas AS (
    SELECT
      w.qtd_value - COALESCE(
        (SELECT td2.sales_points
         FROM public.weekly_cpr_team_detail td2
         JOIN public.weekly_cpr_reports r2 ON r2.id = td2.weekly_cpr_report_id
         WHERE r2.agency_id           = p_agency_id
           AND td2.team_member_id     = w.team_member_id
           AND r2.week_ending_date <  w.week_ending_date
           AND r2.week_ending_date >= w.quarter_start
           AND td2.sales_points IS NOT NULL
         ORDER BY r2.week_ending_date DESC
         LIMIT 1),
        0
      ) AS weekly_delta
    FROM window_rows w
  )
  SELECT AVG(weekly_delta)::numeric FROM with_deltas;
$function$;

COMMENT ON FUNCTION public.team_member_sales_points_avg_13wk(uuid, date) IS
  'Rolling 13-week (91-day) avg of weekly SP earned. Computes per-week delta from QTD-cumulative sales_points (each stored row = quarter-to-date), resets at quarter boundary, then avgs. Used for rating bands (Danger/Caution/Good/Great/Elite).';

COMMENT ON FUNCTION public.agency_sales_points_avg_13wk(uuid, date) IS
  'Rolling 13-week (91-day) avg of weekly SP earned per person-week across the team. Same QTD-aware delta logic as team_member_sales_points_avg_13wk. Used for agency-level rating band on unlimited PTO / 4-day workweek eligibility.';
