DO $m$
DECLARE d text; n text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE ns.nspname='public' AND p.proname='compute_role_earnings_projection';
  n := replace(d, 'public.projected_team_bonus(v_inputs, p.sales_points, 15, rb.base) AS bonus', 'COALESCE(p.expected_team_bonus_annual, 0) AS bonus');
  IF n = d THEN RAISE EXCEPTION 'snippet not found'; END IF;
  EXECUTE n;
END $m$;
