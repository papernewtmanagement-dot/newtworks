-- Saving a sale always marks it entry_source='manual' (that is how a historical
-- row moves into the production log and starts earning credits). A manual row
-- must carry the ECRM link, the GNC answer and the marketing source, which the
-- sales_log_manual_entry_required_fields check constraint enforces. Until now a
-- missing one surfaced as the raw constraint name on screen. Check the merged
-- values here and say what is missing in plain English instead.
CREATE OR REPLACE FUNCTION public.rp_edit_sale(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
  v_today date := public.rp_today_central(); v_on date; prod jsonb; v_keep uuid[] := ARRAY[]::uuid[];
  v_pid uuid; v_lob text; v_type text; v_blocked text; v_was text; v_added boolean; v_new boolean;
  v_ecrm text; v_gnc boolean; v_source text;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that sale was removed. Put it back first.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_was := COALESCE(r.entry_source, 'manual');

  v_on := COALESCE(NULLIF(c->>'submitted_date','')::date, r.submitted_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;

  IF c ? 'household_status' AND lower(COALESCE(c->>'household_status','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'ecrm_opportunity_url' AND btrim(COALESCE(c->>'ecrm_opportunity_url','')) <> ''
     AND btrim(c->>'ecrm_opportunity_url') !~* '^https?://' THEN
    RAISE EXCEPTION 'the ECRM opportunity link must start with http';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  -- What the row will hold once these changes are applied.
  v_ecrm   := NULLIF(btrim(COALESCE(NULLIF(c->>'ecrm_opportunity_url',''), r.ecrm_opportunity_url, '')), '');
  v_gnc    := COALESCE((NULLIF(c->>'gnc_used',''))::boolean, r.gnc_used);
  v_source := NULLIF(COALESCE(NULLIF(c->>'marketing_source',''), r.marketing_source, ''), '');

  IF v_ecrm IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN v_was <> 'manual'
      THEN 'Moving this into the production log needs the ECRM opportunity link.'
      ELSE 'A sale needs the ECRM opportunity link.' END;
  END IF;
  IF v_gnc IS NULL THEN
    RAISE EXCEPTION 'Say whether GNC was used on this sale.';
  END IF;
  IF v_source IS NULL THEN
    RAISE EXCEPTION 'Pick the marketing source.';
  END IF;

  UPDATE public.sales_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    submitted_date        = v_on,
    week_end_date         = public.rp_week_end(v_on),
    household_status      = CASE WHEN c ? 'household_status' THEN lower(c->>'household_status') ELSE household_status END,
    ecrm_opportunity_url  = v_ecrm,
    marketing_source      = v_source,
    gnc_used              = v_gnc,
    note                  = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    entry_source          = 'manual',
    updated_at            = now()
  WHERE id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a sale needs at least one policy';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      PERFORM public.rp_check_sale_product(r.agency_id, prod);
      IF NULLIF(prod->>'id','') IS NOT NULL THEN v_keep := v_keep || (prod->>'id')::uuid; END IF;
    END LOOP;

    SELECT string_agg(DISTINCT p.line_of_business, ', ') INTO v_blocked
      FROM public.sales_log_products p
     WHERE p.sales_log_id = p_id AND NOT (p.id = ANY (v_keep))
       AND EXISTS (SELECT 1 FROM public.cancelation_log x WHERE x.matched_sale_product_id = p.id AND x.status = 'active');
    IF v_blocked IS NOT NULL THEN
      RAISE EXCEPTION 'the % policy has a cancelation logged against it. Remove the cancelation first.', v_blocked;
    END IF;

    UPDATE public.sales_log_products SET multiline_credit_id = NULL
     WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));
    DELETE FROM public.sales_log_products WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));

    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob   := lower(prod->>'line_of_business');
      v_type  := public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
      v_pid   := NULLIF(prod->>'id','')::uuid;
      v_added := (v_lob = 'auto' AND COALESCE((prod->>'added_to_existing')::boolean, false));
      v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
      IF v_pid IS NULL THEN
        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,
                GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
                CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
                v_new, v_added,
                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false));
      ELSE
        UPDATE public.sales_log_products SET
          line_of_business = v_lob, product_type = v_type,
          premium = NULLIF(prod->>'premium','')::numeric,
          policy_count = GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
          vehicle_count = CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
          is_added_to_existing = v_added,
          is_new_line = v_new,
          issued_date = CASE WHEN prod ? 'issued_date' THEN NULLIF(prod->>'issued_date','')::date ELSE issued_date END,
          issued_premium = CASE WHEN prod ? 'issued_premium' THEN NULLIF(prod->>'issued_premium','')::numeric ELSE issued_premium END,
          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END
        WHERE id = v_pid AND sales_log_id = p_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id,
                            'moved_from_historical', (v_was <> 'manual'),
                            'derived', public.rp_derive_sale_credits(p_id));
END $function$;
