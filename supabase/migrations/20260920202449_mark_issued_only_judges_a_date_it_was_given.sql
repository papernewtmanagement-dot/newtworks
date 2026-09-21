-- Peter 2026-09-20: saving David J. failed with "a policy cannot issue before
-- it was submitted" when he was only typing a premium.
--
-- Why: the imported record has the auto issuing 2025-09-02 and the sale
-- submitted 2025-09-12 -- the history came in with the issue date ten days
-- BEFORE the submit date. rp_backfill_save re-sent that stored date with every
-- save, and rp_mark_issued judged it as though he had just typed it.
--
-- The fix is that rp_mark_issued only judges a date it was actually handed.
-- No date in the call now means: keep whatever is on the record, and if the
-- record has none, use the submitted date (Peter's instruction), not today.
-- Nothing silently moves a date that is already stored.

CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_raw text; v_n integer := 0;
  v_today date := public.rp_today_central(); v_synced integer := 0; v_k integer;
  v_given date; v_existing date;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_given := NULLIF(btrim(COALESCE(it->>'issued_date','')), '')::date;
    -- "$1,527.10" is a premium. Drop the formatting, keep the number.
    v_raw := NULLIF(regexp_replace(COALESCE(it->>'issued_premium',''), '[^0-9.\-]', '', 'g'), '');
    IF v_raw IS NOT NULL AND v_raw !~ '^-?[0-9]*\.?[0-9]+$' THEN
      RAISE EXCEPTION 'the issued premium has to be a number';
    END IF;
    v_prem := v_raw::numeric;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;

    SELECT s.submitted_date, p.issued_date INTO v_sub, v_existing
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;

    IF v_given IS NOT NULL THEN
      -- A date was typed, so it gets checked.
      IF v_given > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
      IF v_given < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
      v_on := v_given;
    ELSE
      -- No date given: leave the one on the record alone, however odd it looks.
      -- If there is none, the policy issued when it was submitted.
      v_on := COALESCE(v_existing, v_sub);
    END IF;

    UPDATE public.sales_log_products SET issued_date = v_on, issued_premium = v_prem WHERE id = v_id;
    v_n := v_n + 1;

    -- A live cancelation on this policy recorded the premium as it stood then.
    -- Changing the premium changes what was lost, so the cancelation follows
    -- (Peter 2026-09-20). Only the amount moves; the chargeback points are the
    -- multiline credit times the window left, and that does not depend on it.
    UPDATE public.cancelation_log c
       SET premium = v_prem, updated_at = now()
     WHERE c.matched_sale_product_id = v_id
       AND c.status = 'active'
       AND c.premium IS DISTINCT FROM v_prem;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_synced := v_synced + v_k;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n, 'cancelations_repriced', v_synced);
END $function$;

-- rp_backfill_save stops re-sending the stored date as though it were typed.
-- What he typed goes through; what he did not type is left to the rule above.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_save';

  v_def := replace(v_def,
    $old$               'issued_date', COALESCE(NULLIF(x->>'issued_date',''), (SELECT p.issued_date::text FROM public.sales_log_products p
                                                                       WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id)),$old$,
    $new$               'issued_date', NULLIF(x->>'issued_date',''),$new$);

  IF v_def LIKE '%SELECT p.issued_date::text FROM public.sales_log_products p%' THEN
    RAISE EXCEPTION 'rp_backfill_save did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;
