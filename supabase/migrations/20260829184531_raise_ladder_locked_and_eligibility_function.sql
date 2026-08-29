-- Peter 2026-08-28: THE RAISE LADDER IS NOW LIVE RAISE POLICY, not a
-- projection. pay_scale is the published ladder and this is the function
-- that measures people against it.
--
-- The rule, as Peter set it:
--   Tier 1 is earned on the average over the LAST 1 quarter, tier 2 the
--   LAST 2, tier 3 the LAST 3, and tier 4 and every tier after on the LAST
--   4. Reviewed only at quarter close, one tier per close, in order.
--   Missing a close costs nothing — qualify at the next one and take it.
--   A raise never steps back down.
--
-- Current rate is read off team.pay_rate. SALARY rates are weekly, so the
-- hourly equivalent is the weekly figure over a 40-hour week; HOURLY rates
-- are used as they are. The tier a person sits in is the highest rung at or
-- below that rate, so someone paid between rungs counts as the lower rung
-- and is not skipped past.
--
-- Retention seats are measured on the same weighted basis the Sales Points
-- rating already uses (their points count double against the requirement),
-- which is why the rating and this function agree with each other.

CREATE OR REPLACE FUNCTION public.team_raise_progress(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(
   team_member_id uuid,
   first_name text,
   role_category text,
   weeks_employed integer,
   current_hourly numeric,
   current_tier integer,
   next_tier integer,
   next_hourly numeric,
   next_threshold numeric,
   lookback_quarters integer,
   avg_weekly_sp numeric,
   points_to_go numeric,
   on_track boolean,
   at_top boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH seats AS (
    SELECT t.id, t.first_name, t.role_category,
           CASE WHEN t.hire_date IS NULL THEN 0
                ELSE FLOOR((p_as_of - t.hire_date) / 7.0)::integer END AS weeks_employed,
           CASE WHEN UPPER(COALESCE(t.pay_type,'')) = 'SALARY'
                THEN t.pay_rate / 40.0 ELSE t.pay_rate END AS hourly,
           CASE WHEN t.role_category = 'Retention' THEN 0.5 ELSE 1.0 END AS req_weight
      FROM public.team t
     WHERE t.agency_id = p_agency_id
       AND t.category = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.archived_at IS NULL
       AND t.is_test_user IS NOT TRUE
       AND t.pay_rate IS NOT NULL
  ),
  placed AS (
    SELECT s.*,
           (SELECT p.raise_tier FROM public.pay_scale p
             WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
               AND p.tier_starts_here AND p.base_hourly <= s.hourly
             ORDER BY p.base_hourly DESC LIMIT 1) AS cur_tier
      FROM seats s
  ),
  nxt AS (
    SELECT pl.*,
           n.raise_tier        AS nx_tier,
           n.base_hourly       AS nx_hourly,
           n.sales_points      AS nx_threshold,
           n.lookback_quarters AS nx_lookback
      FROM placed pl
      LEFT JOIN LATERAL (
        SELECT p.raise_tier, p.base_hourly, p.sales_points, p.lookback_quarters
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
           AND p.tier_starts_here AND p.raise_tier > COALESCE(pl.cur_tier, -1)
         ORDER BY p.raise_tier LIMIT 1
      ) n ON true
  )
  SELECT x.id, x.first_name, x.role_category, x.weeks_employed,
         ROUND(x.hourly, 2),
         x.cur_tier,
         x.nx_tier,
         x.nx_hourly,
         x.nx_threshold,
         x.nx_lookback,
         x.avg_sp,
         CASE WHEN x.nx_threshold IS NULL OR x.avg_sp IS NULL THEN NULL
              ELSE GREATEST(ROUND(x.nx_threshold - x.avg_sp, 1), 0) END,
         CASE WHEN x.nx_threshold IS NULL OR x.avg_sp IS NULL THEN false
              ELSE x.avg_sp >= x.nx_threshold END,
         (x.nx_tier IS NULL)
    FROM (
      SELECT n.*,
             CASE WHEN n.nx_lookback IS NULL THEN NULL
                  ELSE ROUND(public.team_member_sales_points_avg_nwk(
                         n.id, n.nx_lookback * 13, p_as_of) / n.req_weight, 2) END AS avg_sp
        FROM nxt n
    ) x
   ORDER BY x.first_name;
$function$;

COMMENT ON FUNCTION public.team_raise_progress(uuid, date) IS
  'Live raise policy. Measures each seat against the published ladder in pay_scale: which rung they are on now, the next rung, the weekly Sales Points average it needs, the look-back window that applies to it, and whether they are currently on track. Reviews happen at quarter close; this is the running picture between them.';

GRANT EXECUTE ON FUNCTION public.team_raise_progress(uuid, date) TO anon, authenticated;

-- Retire the band shim: point the time-off gate at pay_scale.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='time_off_check_eligibility';
  v_new := replace(v_def, 'public.sales_points_band_config', 'public.v_sales_points_bands');
  IF v_new = v_def THEN
    RAISE EXCEPTION 'time_off_check_eligibility does not reference the band shim as expected';
  END IF;
  -- Same shape, new name, sourced from pay_scale.
  EXECUTE v_new;
END
$mig$;
