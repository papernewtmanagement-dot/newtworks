-- Per-teammate Sales Points band + recognition title, for display beside names.
-- Bands locked 2026-08-25 (50/100/300/500). Great = Rockstar, Elite = Rock Legend.
-- Owner, unlicensed (license_pc = false), archived and test seats are never returned:
-- they are not on the ratings ladder at all. Seats inside the 13-week probation are
-- returned with a NULL rating (their average is not yet complete), so callers can
-- tell "no rating yet" apart from "not on the ladder".
-- Retention seats carry half the requirement, matching time_off_check_eligibility:
-- the raw average is divided by 0.5 before it is rated.
CREATE OR REPLACE FUNCTION public.team_sales_points_ratings(p_agency_id uuid)
RETURNS TABLE(
  team_member_id  uuid,
  first_name      text,
  role_category   text,
  weeks_employed  integer,
  avg_13wk        numeric,
  rel_13wk        numeric,
  rating          text,
  title           text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
  WITH seats AS (
    SELECT
      t.id,
      t.first_name,
      t.role_category,
      CASE WHEN t.hire_date IS NULL THEN 0
           ELSE FLOOR((CURRENT_DATE - t.hire_date) / 7.0)::integer END AS weeks_employed,
      CASE WHEN t.role_category = 'Retention' THEN 0.5 ELSE 1.0 END    AS req_weight,
      public.team_member_sales_points_avg_13wk(t.id)                   AS avg_13wk
    FROM public.team t
    WHERE t.agency_id             = p_agency_id
      AND t.category              = 'agency'
      AND COALESCE(t.role_level,'') <> 'Owner'
      AND COALESCE(t.license_pc, false) = true
      AND t.archived_at IS NULL
      AND t.is_test_user IS NOT TRUE
  ),
  rated AS (
    SELECT
      s.*,
      CASE WHEN s.avg_13wk IS NULL THEN NULL
           ELSE ROUND(s.avg_13wk / s.req_weight, 2) END AS rel_13wk
    FROM seats s
  )
  SELECT
    r.id,
    r.first_name,
    r.role_category,
    r.weeks_employed,
    r.avg_13wk,
    r.rel_13wk,
    CASE WHEN r.rel_13wk IS NULL OR r.weeks_employed < 13 THEN NULL
         ELSE public.compute_sales_points_rating(p_agency_id, r.rel_13wk) END AS rating,
    CASE
      WHEN r.rel_13wk IS NULL OR r.weeks_employed < 13 THEN NULL
      WHEN public.compute_sales_points_rating(p_agency_id, r.rel_13wk) = 'Great' THEN 'Rockstar'
      WHEN public.compute_sales_points_rating(p_agency_id, r.rel_13wk) = 'Elite' THEN 'Rock Legend'
      ELSE NULL
    END AS title
  FROM rated r
  ORDER BY r.first_name;
$function$;

GRANT EXECUTE ON FUNCTION public.team_sales_points_ratings(uuid) TO anon, authenticated;
