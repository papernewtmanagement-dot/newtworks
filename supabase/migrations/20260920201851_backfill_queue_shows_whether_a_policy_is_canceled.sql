-- Each policy in the backfill says whether it already has a live cancelation
-- against it, so the screen shows the date instead of offering to add a second.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT replace(
    pg_get_functiondef(p.oid),
    $old$'needs_premium', (p.issued_date IS NOT NULL AND p.issued_premium IS NULL))$old$,
    $new$'needs_premium', (p.issued_date IS NOT NULL AND p.issued_premium IS NULL),
                        'canceled_on', (SELECT c.canceled_on FROM public.cancelation_log c
                                         WHERE c.matched_sale_product_id = p.id AND c.status = 'active' LIMIT 1))$new$
  ) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_queue';

  IF v_def IS NULL OR v_def NOT LIKE '%canceled_on%' THEN
    RAISE EXCEPTION 'rp_backfill_queue did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;
