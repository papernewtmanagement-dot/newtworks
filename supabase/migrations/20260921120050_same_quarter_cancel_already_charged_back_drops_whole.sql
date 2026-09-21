-- Keep the earlier behavior for a same-quarter cancelation already charged back
-- when it happened: the policy drops out whole.
DO $mig$
DECLARE d text; o text;
BEGIN
  SELECT pg_get_functiondef('public.production_rows_for(uuid,date,date)'::regprocedure) INTO d;
  o := $o$    SELECT b.id, cx.left_frac
      FROM base b JOIN cxl cx ON cx.pid = b.id CROSS JOIN anchor a
     WHERE NOT cx.already_charged_back
       AND floor$o$;
  IF position(o IN d) = 0 THEN RAISE EXCEPTION 'same_q not found'; END IF;
  d := replace(d, o, $n$    SELECT b.id, CASE WHEN cx.already_charged_back THEN 1 ELSE cx.left_frac END AS left_frac
      FROM base b JOIN cxl cx ON cx.pid = b.id CROSS JOIN anchor a
     WHERE floor$n$);
  EXECUTE d;
END $mig$;
