-- Peter 2026-08-28, two corrections to the live raise policy.
--
-- 1. MANAGER TITLE STEPS. From the Raise System 2 design: Unit Manager
--    +$3/hr, Section Manager +$6/hr, Office Manager +$9/hr, paid ON TOP of
--    the raise tier. Without this the function read a manager's title money
--    as ladder progress and placed them far too high — Thomas showed six
--    rungs ahead of his production when three of those dollars are his Unit
--    Manager step, not a tier. They live in pay_scale as their own rows
--    (role_key = 'title_step'), so all pay stays in one table. reseed only
--    touches the sales rows, so these survive it.
--
-- 2. RETENTION IS LICENCE DRIVEN, NOT PACE DRIVEN. Their steps are $16 with
--    no licence, $18 with Property & Casualty, $20 with both. The function
--    was measuring them against sales-point thresholds they will never hit.
--    The licence each step needs is now structured, not prose, so it can be
--    compared against team.license_pc / license_lh. on_track for a retention
--    seat means holding the licence the next step calls for.

ALTER TABLE public.pay_scale
  ADD COLUMN IF NOT EXISTS title_label           text,
  ADD COLUMN IF NOT EXISTS retention_requires_pc boolean,
  ADD COLUMN IF NOT EXISTS retention_requires_lh boolean;

COMMENT ON COLUMN public.pay_scale.title_label IS
  'On role_key = title_step rows: the management title this hourly step is paid for. base_hourly on those rows is the INCREMENT added on top of the raise tier, not a rate.';
COMMENT ON COLUMN public.pay_scale.retention_requires_pc IS
  'Structured form of retention_requirement so it can be compared against team.license_pc / license_lh rather than parsed from prose.';

INSERT INTO public.pay_scale (agency_id, role_key, sales_points, base_hourly, base_annual, title_label, updated_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','title_step',  0, 3, 0, 'Unit Manager',    now()),
  ('126794dd-25ff-47d2-a436-724499733365','title_step', 10, 6, 0, 'Section Manager', now()),
  ('126794dd-25ff-47d2-a436-724499733365','title_step', 20, 9, 0, 'Office Manager',  now())
ON CONFLICT (agency_id, role_key, sales_points) DO UPDATE
  SET base_hourly = EXCLUDED.base_hourly, title_label = EXCLUDED.title_label, updated_at = now();

UPDATE public.pay_scale p SET retention_requires_pc = v.pc, retention_requires_lh = v.lh
  FROM (VALUES (16,false,false),(18,true,false),(20,true,true)) AS v(hr, pc, lh)
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND p.role_key = 'sales' AND p.retention_requirement IS NOT NULL AND p.base_hourly = v.hr;

DROP FUNCTION IF EXISTS public.team_raise_progress(uuid, date);

CREATE FUNCTION public.team_raise_progress(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(
   team_member_id uuid, first_name text, role_category text, role_level text,
   weeks_employed integer, current_hourly numeric, title_increment numeric,
   tier_hourly numeric, current_tier integer, next_tier integer, next_hourly numeric,
   next_requirement text, next_threshold numeric, lookback_quarters integer,
   avg_weekly_sp numeric, points_to_go numeric, on_track boolean, at_top boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH seats AS (
    SELECT t.id, t.first_name, t.role_category, t.role_level,
           COALESCE(t.license_pc,false) AS has_pc, COALESCE(t.license_lh,false) AS has_lh,
           CASE WHEN t.hire_date IS NULL THEN 0
                ELSE FLOOR((p_as_of - t.hire_date) / 7.0)::integer END AS weeks_employed,
           CASE WHEN UPPER(COALESCE(t.pay_type,'')) = 'SALARY'
                THEN t.pay_rate / 40.0 ELSE t.pay_rate END AS hourly,
           CASE WHEN t.role_category = 'Retention' THEN 0.5 ELSE 1.0 END AS req_weight,
           COALESCE((SELECT s.base_hourly FROM public.pay_scale s
                      WHERE s.agency_id = p_agency_id AND s.role_key = 'title_step'
                        AND s.title_label = t.role_level LIMIT 1), 0) AS title_inc
      FROM public.team t
     WHERE t.agency_id = p_agency_id AND t.category = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
       AND t.pay_rate IS NOT NULL
  ),
  placed AS (
    SELECT s.*, (s.hourly - s.title_inc) AS tier_rate,
           (SELECT p.raise_tier FROM public.pay_scale p
             WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
               AND p.tier_starts_here AND p.base_hourly <= (s.hourly - s.title_inc)
             ORDER BY p.base_hourly DESC LIMIT 1) AS cur_tier
      FROM seats s
  ),
  nxt AS (
    SELECT pl.*, n.raise_tier AS nx_tier, n.base_hourly AS nx_hourly,
           n.sales_points AS nx_threshold, n.lookback_quarters AS nx_lookback,
           n.retention_requirement AS nx_req, n.retention_requires_pc AS nx_pc,
           n.retention_requires_lh AS nx_lh
      FROM placed pl
      LEFT JOIN LATERAL (
        SELECT p.raise_tier, p.base_hourly, p.sales_points, p.lookback_quarters,
               p.retention_requirement, p.retention_requires_pc, p.retention_requires_lh
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
           AND p.raise_tier > COALESCE(pl.cur_tier, -1)
           -- Retention climbs the licence steps; everyone else the pace ladder.
           AND (pl.role_category IS DISTINCT FROM 'Retention' OR p.retention_requirement IS NOT NULL)
         ORDER BY p.raise_tier LIMIT 1
      ) n ON true
  )
  SELECT x.id, x.first_name, x.role_category, x.role_level, x.weeks_employed,
         ROUND(x.hourly, 2), x.title_inc, ROUND(x.tier_rate, 2),
         x.cur_tier, x.nx_tier, x.nx_hourly + x.title_inc,
         CASE WHEN x.role_category = 'Retention' THEN x.nx_req
              WHEN x.nx_threshold IS NULL THEN NULL
              ELSE x.nx_threshold::text || ' a week averaged over the last ' || x.nx_lookback
                   || CASE WHEN x.nx_lookback = 1 THEN ' quarter' ELSE ' quarters' END END,
         CASE WHEN x.role_category = 'Retention' THEN NULL ELSE x.nx_threshold END,
         CASE WHEN x.role_category = 'Retention' THEN NULL ELSE x.nx_lookback END,
         x.avg_sp,
         CASE WHEN x.role_category = 'Retention' OR x.nx_threshold IS NULL OR x.avg_sp IS NULL
              THEN NULL ELSE GREATEST(ROUND(x.nx_threshold - x.avg_sp, 1), 0) END,
         CASE WHEN x.nx_tier IS NULL THEN false
              WHEN x.role_category = 'Retention'
                THEN (x.has_pc OR NOT COALESCE(x.nx_pc,false))
                 AND (x.has_lh OR NOT COALESCE(x.nx_lh,false))
              WHEN x.nx_threshold IS NULL OR x.avg_sp IS NULL THEN false
              ELSE x.avg_sp >= x.nx_threshold END,
         (x.nx_tier IS NULL)
    FROM (
      SELECT n.*,
             CASE WHEN n.role_category = 'Retention' OR n.nx_lookback IS NULL THEN NULL
                  ELSE ROUND(public.team_member_sales_points_avg_nwk(
                         n.id, n.nx_lookback * 13, p_as_of) / n.req_weight, 2) END AS avg_sp
        FROM nxt n
    ) x
   ORDER BY x.first_name;
$function$;

GRANT EXECUTE ON FUNCTION public.team_raise_progress(uuid, date) TO anon, authenticated;
