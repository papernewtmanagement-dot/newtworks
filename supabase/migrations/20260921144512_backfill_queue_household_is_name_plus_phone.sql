DO $mig$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.rp_backfill_queue'::regproc);
  a := 'lower(btrim(g.customer_label)) AS household,';
  IF position(a IN d) = 0 THEN RAISE EXCEPTION 'rp_backfill_queue shape changed'; END IF;
  d := replace(d, a,
    '-- A household is the name AND the phone. Same name, different phone = a
           -- different household (the three James W.s, 2026-09-21). Matches how the
           -- save spreads values: only to records with the same phone or none.
           lower(btrim(g.customer_label)) || ''|'' || COALESCE(g.phone_last4, '''') AS household,');
  EXECUTE d;
END
$mig$;

UPDATE public.sales_log SET week_end_date = public.rp_week_end(submitted_date), updated_at = now()
 WHERE id = '06292c4e-6378-46d3-88e8-bd07a587e51d' AND week_end_date IS DISTINCT FROM public.rp_week_end(submitted_date);
