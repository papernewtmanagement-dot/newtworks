-- Peter 2026-09-20: a policy cannot have issued before the sale was submitted.
-- Where the imported history says otherwise, the issue date moves up to the
-- submit date. One record is in that state today: David J.'s auto, which came
-- in issuing 2025-09-02 against a 2025-09-12 submit.
--
-- The same rule now holds going forward. rp_mark_issued still refuses a date
-- someone TYPES that is earlier than the submit date -- that is a typo and he
-- should see it. But a date it was not given, sitting on the record from the
-- import, is brought up rather than left wrong or left blocking the save.

UPDATE public.sales_log_products p
   SET issued_date = s.submitted_date
  FROM public.sales_log s
 WHERE s.id = p.sales_log_id
   AND s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND s.status = 'active'
   AND p.issued_date IS NOT NULL
   AND p.issued_date < s.submitted_date;

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
      -- No date given: keep the one on the record, except that a date earlier
      -- than the submit date is impossible, so it moves up to it. No date at
      -- all means the policy issued when it was submitted.
      v_on := GREATEST(COALESCE(v_existing, v_sub), v_sub);
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
