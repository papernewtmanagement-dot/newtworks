-- 1. The one rule for "which CPR does something recorded at p_at belong to":
--    the most recent CPR not yet locked by payroll. Last week until its payroll
--    lands, then this week. Weeks older than the payroll-lock system count as locked.
CREATE OR REPLACE FUNCTION public.cpr_week_for(p_agency uuid, p_at timestamp with time zone)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH w AS (SELECT public.rp_week_end((p_at AT TIME ZONE 'America/Chicago')::date) AS this_end)
  SELECT CASE WHEN NOT EXISTS (
                SELECT 1 FROM public.weekly_pool_lock l
                 WHERE l.agency_id = p_agency
                   AND l.week_end_date = w.this_end - 7
                   AND l.locked_at <= p_at)
               AND w.this_end - 7 >= COALESCE(
                (SELECT min(l2.week_end_date) FROM public.weekly_pool_lock l2 WHERE l2.agency_id = p_agency),
                DATE '9999-12-31')
              THEN w.this_end - 7
              ELSE w.this_end END
    FROM w;
$function$;

-- 2. production_rows_for: drop the inline copy, call cpr_week_for.
DO $mig$
DECLARE d text; a text; b text;
BEGIN
  d := pg_get_functiondef('public.production_rows_for'::regproc);
  a := '-- Peter 2026-09-21: a cancelation or chargeback counts toward the last CPR
           -- until that CPR is frozen (sent). Recorded after its week ended but before
           -- it was sent -> it lands on that week. Otherwise on the day recorded.
           CASE WHEN NOT EXISTS (
                  SELECT 1 FROM public.weekly_cpr_reports r
                   WHERE r.agency_id = c.agency_id
                     AND r.week_ending_date = rd.prev_sat
                     AND r.sent_to_team_at IS NOT NULL
                     AND r.sent_to_team_at <= c.created_at)
                THEN rd.prev_sat ELSE rd.d END AS recorded_on';
  b := 'CROSS JOIN LATERAL (
        SELECT (c.created_at AT TIME ZONE ''America/Chicago'')::date AS d,
               (c.created_at AT TIME ZONE ''America/Chicago'')::date
                 - (EXTRACT(DOW FROM (c.created_at AT TIME ZONE ''America/Chicago''))::int + 1) AS prev_sat
      ) rd';
  IF position(a IN d) = 0 OR position(b IN d) = 0 THEN
    RAISE EXCEPTION 'production_rows_for changed shape; re-read before patching';
  END IF;
  d := replace(d, a,
    '-- Peter 2026-09-21: cancelations and chargebacks count toward the most recent
           -- CPR not yet locked by payroll. cpr_week_for is the one rule for that.
           CASE WHEN public.cpr_week_for(c.agency_id, c.created_at) < public.rp_week_end(rd.d)
                THEN public.cpr_week_for(c.agency_id, c.created_at) ELSE rd.d END AS recorded_on');
  d := replace(d, b,
    'CROSS JOIN LATERAL (SELECT (c.created_at AT TIME ZONE ''America/Chicago'')::date AS d) rd');
  EXECUTE d;
END
$mig$;

-- 3. Lock sales points when payroll lands, not when the CPR is sent.
DROP TRIGGER IF EXISTS freeze_sales_points_on_send ON public.weekly_cpr_reports;
DROP FUNCTION IF EXISTS public.trg_freeze_sales_points_on_send();

CREATE OR REPLACE FUNCTION public.trg_freeze_sales_points_on_payroll_lock()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  PERFORM public.freeze_sales_points_for_week(NEW.agency_id, NEW.week_end_date);
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS freeze_sales_points_on_payroll_lock ON public.weekly_pool_lock;
CREATE TRIGGER freeze_sales_points_on_payroll_lock
  AFTER INSERT ON public.weekly_pool_lock
  FOR EACH ROW EXECUTE FUNCTION public.trg_freeze_sales_points_on_payroll_lock();

-- 4. Unlock week ending 2026-09-19: payroll has not landed for it.
UPDATE public.weekly_cpr_team_detail d
   SET sales_points_frozen = NULL, sales_points_frozen_at = NULL, sales_points_frozen_source = NULL
  FROM public.weekly_cpr_reports r
 WHERE d.weekly_cpr_report_id = r.id
   AND r.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND r.week_ending_date = DATE '2026-09-19'
   AND NOT EXISTS (SELECT 1 FROM public.weekly_pool_lock l
                    WHERE l.agency_id = r.agency_id AND l.week_end_date = r.week_ending_date);
