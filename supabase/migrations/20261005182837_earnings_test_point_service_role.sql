DO $m$
DECLARE d text; n text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='public' AND p.proname='earnings_test_point';
  n := replace(d, 'IF NOT public.is_agency_admin() THEN', 'IF NOT (auth.role() IS NULL OR auth.role() = ''service_role'' OR public.is_agency_admin()) THEN');
  IF n = d THEN RAISE EXCEPTION 'snippet not found'; END IF;
  EXECUTE n;
END $m$;
