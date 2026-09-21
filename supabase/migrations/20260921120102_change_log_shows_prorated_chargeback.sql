DO $mig$
DECLARE d text; o text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;
  o := $o$'charge', CASE WHEN x.effect IN ('charged_back', 'removed') THEN COALESCE(x.issued_premium, x.premium) ELSE 0 END,$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'charge not found'; END IF;
  d := replace(d, o, $n$'charge', CASE WHEN x.effect IN ('charged_back', 'removed')
                            THEN round(COALESCE(x.issued_premium, x.premium)
                                       * LEAST(1, GREATEST(0, COALESCE((x.cxl_row ->> 'window_fraction_left')::numeric, 1))), 2)
                            ELSE 0 END,
             'window_left', (x.cxl_row ->> 'window_fraction_left')::numeric,$n$);
  o := $o$THEN ', charged back ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium')$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'cb line not found'; END IF;
  d := replace(d, o, $n$THEN ', charged back ' || public.change_value_text(p_agency_id, 'premium', i.policy -> 'charge')
                         || COALESCE(' (' || round((i.policy ->> 'window_left')::numeric * 100) || '% of the window left)', '')$n$);
  o := $o$|| ' issue (' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium') || ')'$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'removed line not found'; END IF;
  d := replace(d, o, $n$|| ' issue (' || public.change_value_text(p_agency_id, 'premium', i.policy -> 'charge') || ' unearned)'$n$);
  EXECUTE d;
END $mig$;
