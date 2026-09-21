-- THE one answer to "is this week locked, and since when": payroll landing.
-- Weeks older than the payroll-lock system count as locked forever.
CREATE OR REPLACE FUNCTION public.week_locked_at(p_agency uuid, p_week_end date)
 RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $f$
  SELECT COALESCE(
    (SELECT l.locked_at FROM public.weekly_pool_lock l
      WHERE l.agency_id = p_agency AND l.week_end_date = p_week_end),
    CASE WHEN p_week_end < (SELECT min(l2.week_end_date) FROM public.weekly_pool_lock l2 WHERE l2.agency_id = p_agency)
         THEN '-infinity'::timestamptz END)
$f$;

-- Last locked week, derived from the lock instead of a hand-typed date.
CREATE OR REPLACE FUNCTION public.rp_reported_through(p_agency uuid)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $f$
  SELECT COALESCE(max(l.week_end_date), DATE '1900-01-01')
    FROM public.weekly_pool_lock l WHERE l.agency_id = p_agency
$f$;

CREATE OR REPLACE FUNCTION public.cpr_week_for(p_agency uuid, p_at timestamp with time zone)
 RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH w AS (SELECT public.rp_week_end((p_at AT TIME ZONE 'America/Chicago')::date) AS this_end)
  SELECT CASE WHEN COALESCE(public.week_locked_at(p_agency, w.this_end - 7) <= p_at, false)
              THEN w.this_end ELSE w.this_end - 7 END
    FROM w;
$function$;

DO $mig$
DECLARE d text; a text; fn text;
BEGIN
  -- callers of the hard-coded reported-through date
  FOREACH fn IN ARRAY ARRAY['get_sales_points_qtd','rp_week_scoreboard_for','production_by_week_for'] LOOP
    d := pg_get_functiondef(fn::regproc);
    IF position('public.rp_reported_through()' IN d) = 0 THEN RAISE EXCEPTION '% shape changed', fn; END IF;
    d := replace(d, 'public.rp_reported_through()', 'public.rp_reported_through(p_agency_id)');
    EXECUTE d;
  END LOOP;

  d := pg_get_functiondef('public.reset_open_week_snapshots'::regproc);
  a := 'SELECT EXISTS (SELECT 1 FROM public.weekly_pool_lock wl
                 WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date)
    INTO v_locked;';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'reset_open_week_snapshots shape changed'; END IF;
  d := replace(d, a, 'v_locked := public.week_locked_at(p_agency_id, p_week_end_date) IS NOT NULL;');
  EXECUTE d;

  d := pg_get_functiondef('public.write_weekly_comp_v2'::regproc);
  a := 'IF EXISTS (SELECT 1 FROM public.weekly_pool_lock wl
             WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date) THEN';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'write_weekly_comp_v2 shape changed'; END IF;
  d := replace(d, a, 'IF public.week_locked_at(p_agency_id, p_week_end_date) IS NOT NULL THEN');
  EXECUTE d;

  d := pg_get_functiondef('public.week_pay_lock'::regproc);
  a := '''locked'',              (l.week_end_date IS NOT NULL),';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'week_pay_lock shape changed'; END IF;
  d := replace(d, a, '''locked'',              (public.week_locked_at(p_agency_id, p_week_end_date) IS NOT NULL),');
  EXECUTE d;
END
$mig$;

DROP FUNCTION public.rp_reported_through();
