-- Peter 2026-09-20: "Why do I have to keep spelling out all the things that I
-- need to be able to edit?" He shouldn't. The backfill now edits every field
-- that matters on an imported record, not only the ones that are blank:
--
--   household   phone, marketing source, ECRM link, referral detail
--   record      submitted date
--   policy      product type, cars, issued date, issued premium, added car, canceled
--
-- Order inside one save, so each step sees the one before it:
--   submitted date -> household fields -> type/cars -> issued -> added car -> canceled -> spread
--
-- A household value he changes spreads to the rest of the household -- the
-- records under that name that had nothing, or had the value he just replaced.
-- A different household that happens to share the name keeps its own.

-- rp_mark_issued: correcting the date on a policy that already issued does not
-- need the premium typed again. A policy being issued for the first time still
-- does, so the To Be Issued tab behaves exactly as before.
CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_raw text; v_n integer := 0;
  v_today date := public.rp_today_central(); v_synced integer := 0; v_k integer;
  v_given date; v_existing date; v_existing_prem numeric;
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

    SELECT s.submitted_date, p.issued_date, p.issued_premium INTO v_sub, v_existing, v_existing_prem
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;

    v_prem := COALESCE(v_raw::numeric, CASE WHEN v_existing IS NOT NULL THEN v_existing_prem END);
    IF v_prem IS NULL AND v_existing IS NULL THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem IS NOT NULL AND v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;

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
    -- Changing the premium changes what was lost, so the cancelation follows.
    IF v_prem IS NOT NULL THEN
      UPDATE public.cancelation_log c
         SET premium = v_prem, updated_at = now()
       WHERE c.matched_sale_product_id = v_id
         AND c.status = 'active'
         AND c.premium IS DISTINCT FROM v_prem;
      GET DIAGNOSTICS v_k = ROW_COUNT; v_synced := v_synced + v_k;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n, 'cancelations_repriced', v_synced);
END $function$;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; pol jsonb; v_id uuid; v_kind text; v_label text;
  v_phone text; v_ecrm text; v_src text; v_refcust text; v_refby uuid; v_sub date;
  v_old_phone text; v_old_ecrm text; v_old_src text;
  v_items jsonb; v_touched boolean;
  v_saved integer := 0; v_spread integer := 0; v_issued integer := 0; n integer;
  v_canceled integer := 0; v_charged integer := 0;
  v_on date; v_res jsonb; sp RECORD; sl RECORD; v_type text; v_veh integer;
  v_today date := public.rp_today_central();
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'nothing to save'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'more than 200 rows in one save. Do it in two passes.'; END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_kind := lower(COALESCE(rec->>'kind',''));
    v_id   := NULLIF(rec->>'id','')::uuid;
    IF v_id IS NULL OR v_kind NOT IN ('sale','quote') THEN CONTINUE; END IF;
    v_touched := false;

    -- What this record holds right now, before anything changes.
    IF v_kind = 'sale' THEN
      SELECT customer_label, phone_last4, ecrm_opportunity_url, marketing_source
        INTO v_label, v_old_phone, v_old_ecrm, v_old_src
        FROM public.sales_log WHERE id = v_id AND agency_id = a.agency_id AND status = 'active';
    ELSE
      SELECT customer_label, phone_last4, NULL::text, marketing_source
        INTO v_label, v_old_phone, v_old_ecrm, v_old_src
        FROM public.quote_log WHERE id = v_id AND agency_id = a.agency_id AND status = 'active';
    END IF;
    IF v_label IS NULL THEN CONTINUE; END IF;

    -- ---- 1. submitted date ---------------------------------------------------
    v_sub := NULLIF(btrim(COALESCE(rec->>'submitted_date','')), '')::date;
    IF v_sub IS NOT NULL THEN
      IF v_sub > v_today THEN RAISE EXCEPTION 'the submitted date cannot be in the future'; END IF;
      IF v_kind = 'sale' THEN
        UPDATE public.sales_log SET submitted_date = v_sub, week_end_date = public.rp_week_end(v_sub), updated_at = now()
         WHERE id = v_id AND submitted_date IS DISTINCT FROM v_sub;
        GET DIAGNOSTICS n = ROW_COUNT;
        -- A policy cannot have issued before the sale was submitted.
        UPDATE public.sales_log_products SET issued_date = v_sub
         WHERE sales_log_id = v_id AND issued_date IS NOT NULL AND issued_date < v_sub;
      ELSE
        UPDATE public.quote_log SET quote_date = v_sub, week_end_date = public.rp_week_end(v_sub), updated_at = now()
         WHERE id = v_id AND quote_date IS DISTINCT FROM v_sub;
        GET DIAGNOSTICS n = ROW_COUNT;
      END IF;
      IF n > 0 THEN v_touched := true; END IF;
    END IF;

    -- ---- 2. household fields -------------------------------------------------
    v_phone := NULLIF(regexp_replace(COALESCE(rec->>'phone_last4',''), '\D', '', 'g'), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^\d{4}$' THEN
      RAISE EXCEPTION 'the last four digits of the phone, four numbers';
    END IF;
    v_ecrm := NULLIF(btrim(COALESCE(rec->>'ecrm','')), '');
    IF v_ecrm IS NOT NULL AND v_ecrm !~* '^https?://' THEN
      RAISE EXCEPTION 'an ECRM link has to start with http';
    END IF;
    v_src := NULLIF(btrim(COALESCE(rec->>'marketing_source','')), '');
    IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
        WHERE agency_id = a.agency_id AND source_key = v_src AND is_active) THEN
      RAISE EXCEPTION 'pick the marketing source';
    END IF;
    v_refcust := NULLIF(btrim(COALESCE(rec->>'referred_by_customer','')), '');
    v_refby   := NULLIF(rec->>'sourced_by_team_member_id','')::uuid;

    IF v_phone IS NOT NULL OR v_ecrm IS NOT NULL OR v_src IS NOT NULL OR v_refcust IS NOT NULL OR v_refby IS NOT NULL THEN
      IF v_kind = 'sale' THEN
        UPDATE public.sales_log SET
          phone_last4 = COALESCE(v_phone, phone_last4),
          ecrm_opportunity_url = COALESCE(v_ecrm, ecrm_opportunity_url),
          marketing_source = COALESCE(v_src, marketing_source),
          referred_by_customer = COALESCE(v_refcust, referred_by_customer),
          sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
          updated_at = now()
        WHERE id = v_id;
      ELSE
        UPDATE public.quote_log SET
          phone_last4 = COALESCE(v_phone, phone_last4),
          marketing_source = COALESCE(v_src, marketing_source),
          referred_by_customer = COALESCE(v_refcust, referred_by_customer),
          sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
          updated_at = now()
        WHERE id = v_id;
      END IF;
      v_touched := true;
    END IF;

    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      -- ---- 3. product type and cars ------------------------------------------
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        SELECT p.* INTO sp FROM public.sales_log_products p
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;
        CONTINUE WHEN sp.id IS NULL;
        IF NULLIF(btrim(COALESCE(pol->>'product_type','')), '') IS NOT NULL THEN
          v_type := public.rp_check_product_type(a.agency_id, sp.line_of_business, pol->>'product_type');
          UPDATE public.sales_log_products SET product_type = v_type
           WHERE id = sp.id AND product_type IS DISTINCT FROM v_type;
          GET DIAGNOSTICS n = ROW_COUNT; IF n > 0 THEN v_touched := true; END IF;
        END IF;
        IF sp.line_of_business = 'auto' AND NULLIF(btrim(COALESCE(pol->>'vehicle_count','')), '') IS NOT NULL THEN
          v_veh := (pol->>'vehicle_count')::integer;
          IF v_veh < 1 OR v_veh > 20 THEN RAISE EXCEPTION 'how many cars on that auto policy?'; END IF;
          UPDATE public.sales_log_products SET vehicle_count = v_veh
           WHERE id = sp.id AND vehicle_count IS DISTINCT FROM v_veh;
          GET DIAGNOSTICS n = ROW_COUNT; IF n > 0 THEN v_touched := true; END IF;
        END IF;
      END LOOP;

      -- ---- 4. issued date and premium, through rp_mark_issued -----------------
      -- Runs BEFORE any cancelation, so a chargeback logged in the same save is
      -- priced off the premium being applied, not the old one.
      SELECT jsonb_agg(jsonb_build_object(
               'sale_product_id', x->>'id',
               'issued_date', NULLIF(x->>'issued_date',''),
               'issued_premium', NULLIF(x->>'issued_premium','')))
        INTO v_items
        FROM jsonb_array_elements(rec->'policies') x
       WHERE (NULLIF(btrim(COALESCE(x->>'issued_premium','')), '') IS NOT NULL
              OR NULLIF(btrim(COALESCE(x->>'issued_date','')), '') IS NOT NULL)
         AND EXISTS (SELECT 1 FROM public.sales_log_products p
                      WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id);
      IF v_items IS NOT NULL AND jsonb_array_length(v_items) > 0 THEN
        PERFORM public.rp_mark_issued(v_items);
        v_issued := v_issued + jsonb_array_length(v_items);
        v_touched := true;
      END IF;

      -- ---- 5. added car ---------------------------------------------------------
      -- Credits on a backfilled sale are locked, so this corrects the record and
      -- moves no points.
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        CONTINUE WHEN NOT (pol ? 'added_to_existing');
        UPDATE public.sales_log_products p
           SET is_added_to_existing = COALESCE((pol->>'added_to_existing')::boolean, false),
               is_new_line = NOT COALESCE((pol->>'added_to_existing')::boolean, false)
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id
           AND p.line_of_business = 'auto'
           AND p.is_added_to_existing IS DISTINCT FROM COALESCE((pol->>'added_to_existing')::boolean, false);
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n > 0 THEN v_touched := true; END IF;
      END LOOP;

      -- ---- 6. canceled ----------------------------------------------------------
      -- Logged through rp_log_cancelation like every other cancelation. The
      -- backfill flag lifts only the 90-day floor and marks it as history, which
      -- keeps it from paying anyone a logging credit.
      SELECT s.* INTO sl FROM public.sales_log s WHERE s.id = v_id;
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        v_on := NULLIF(btrim(COALESCE(pol->>'canceled_on','')), '')::date;
        CONTINUE WHEN v_on IS NULL;
        SELECT p.* INTO sp FROM public.sales_log_products p
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;
        CONTINUE WHEN sp.id IS NULL;
        CONTINUE WHEN EXISTS (SELECT 1 FROM public.cancelation_log c
                               WHERE c.matched_sale_product_id = sp.id AND c.status = 'active');
        IF sl.ecrm_opportunity_url IS NULL OR btrim(sl.ecrm_opportunity_url) = '' THEN
          RAISE EXCEPTION 'marking % canceled needs the ECRM link on the household first', sl.customer_label;
        END IF;
        v_res := public.rp_log_cancelation(jsonb_build_object(
          'backfill', true,
          'team_member_id', sl.team_member_id,
          'customer_first', sl.customer_first_name,
          'customer_last_initial', sl.customer_last_initial,
          'customer_kind', sl.customer_kind,
          'canceled_on', v_on::text,
          'policy_line', sp.line_of_business,
          'product_type', sp.product_type,
          'premium', COALESCE(sp.issued_premium, sp.premium)::text,
          'vehicle_count', sp.vehicle_count::text,
          'matched_sale_product_id', sp.id::text,
          'ecrm_url', sl.ecrm_opportunity_url,
          'reason', 'Backfilled from the history load',
          'note', 'Marked canceled from the Backfill tab'));
        v_canceled := v_canceled + 1;
        IF COALESCE((v_res->>'matched')::boolean, false) THEN v_charged := v_charged + 1; END IF;
        v_touched := true;
      END LOOP;
    END IF;

    IF v_touched THEN v_saved := v_saved + 1; END IF;

    -- ---- 7. spread household values to the rest of the household -------------
    -- Same household = same name, and a value that is empty or is the one just
    -- replaced. A different household that shares the name keeps its own.
    IF v_phone IS NOT NULL THEN
      UPDATE public.sales_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.quote_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.cancelation_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.retention_activity_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status <> 'void' AND customer_label = v_label
         AND (phone_last4 IS NULL OR phone_last4 = v_old_phone) AND phone_last4 IS DISTINCT FROM v_phone;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    IF v_src IS NOT NULL THEN
      UPDATE public.sales_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (COALESCE(btrim(marketing_source), '') = '' OR marketing_source = v_old_src)
         AND marketing_source IS DISTINCT FROM v_src;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
      UPDATE public.quote_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (COALESCE(btrim(marketing_source), '') = '' OR marketing_source = v_old_src)
         AND marketing_source IS DISTINCT FROM v_src;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;

    IF v_ecrm IS NOT NULL THEN
      UPDATE public.sales_log SET ecrm_opportunity_url = v_ecrm, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND (COALESCE(btrim(ecrm_opportunity_url), '') = '' OR ecrm_opportunity_url = v_old_ecrm)
         AND ecrm_opportunity_url IS DISTINCT FROM v_ecrm;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;
  END LOOP;

  UPDATE public.cancelation_log c SET phone_last4 = s.phone_last4, updated_at = now()
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE c.matched_sale_product_id = p.id
     AND c.agency_id = a.agency_id AND c.status = 'active'
     AND c.phone_last4 IS NULL AND s.phone_last4 IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_saved, 'policies_issued', v_issued,
                            'also_filled', v_spread,
                            'policies_canceled', v_canceled, 'charged_back', v_charged);
END $function$;
