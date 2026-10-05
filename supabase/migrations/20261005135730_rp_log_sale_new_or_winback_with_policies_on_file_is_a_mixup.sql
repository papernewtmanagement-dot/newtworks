CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text;
  v_sale_id uuid; prod jsonb; v_lob text; v_type text; v_prem numeric;
  v_cnt integer; v_new boolean; v_added boolean; v_veh integer; v_note text; v_derived jsonb;
  v_phone text;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'submitted_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;
  IF v_on < v_today - 30 THEN RAISE EXCEPTION 'log a sale within 30 days of the bind'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);
  v_status := lower(COALESCE(p->>'household_status',''));
  IF v_status NOT IN ('new','existing','winback') THEN RAISE EXCEPTION 'pick the relationship type: new, existing, or winback'; END IF;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NULL OR v_url !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM opportunity link is required (must start with http)'; END IF;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  v_note := NULLIF(btrim(COALESCE(p->>'note','')),'');
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'a sale needs a note on what happened, so it can be checked later';
  END IF;

  IF jsonb_typeof(p->'products') <> 'array' OR jsonb_array_length(p->'products') = 0 THEN
    RAISE EXCEPTION 'add at least one policy with its premium';
  END IF;
  IF jsonb_array_length(p->'products') > 40 THEN RAISE EXCEPTION 'more than 40 policies in one sale. Double-check it.'; END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    PERFORM public.rp_check_sale_product(a.agency_id, prod);
  END LOOP;

  INSERT INTO public.sales_log (agency_id, team_member_id, submitted_date, week_end_date,
    customer_first_name, customer_last_initial, customer_kind, household_status, ecrm_opportunity_url,
    marketing_source, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_status, v_url,
    v_src, NULL, 0, v_note, a.actor_id, NULLIF(btrim(COALESCE(p->>'on_file_answer','')), ''), NULLIF(p->>'replaced_sale_product_id','')::uuid)
  RETURNING id INTO v_sale_id;

  SELECT phone_last4 INTO v_phone FROM public.sales_log WHERE id = v_sale_id;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob   := lower(prod->>'line_of_business');
    v_type  := public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem  := NULLIF(prod->>'premium','')::numeric;
    v_cnt   := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    -- ticked by the team, OR the household already has this same auto product on file
    v_added := (v_lob = 'auto' AND (
                  COALESCE((prod->>'added_to_existing')::boolean, false)
                  OR public.rp_auto_on_file(a.agency_id, v_label, v_phone, v_type, v_on, v_sale_id)));
    -- a vehicle added to a policy they already have is not a new line
    v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
    v_veh   := CASE WHEN v_lob = 'auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, autopay_enrolled, insured_name)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_added, NULLIF(prod->>'issued_date','')::date, COALESCE((prod->>'autopay')::boolean, false),
            CASE WHEN v_lob = 'life' THEN COALESCE(NULLIF(btrim(COALESCE(prod->>'insured_name', '')), ''), v_label) END);
  END LOOP;

  /* Peter 2026-10-05: a New or Winback customer with policies still on file is a mix-up to clear
     up first. Either the cancelation was never logged or the relationship is really Existing. */
  IF v_status IN ('new', 'winback') AND public.rp_household_on_file(v_sale_id) THEN
    RAISE EXCEPTION '% already has policies on file, so they are not %. Switch the relationship to Existing, or log the cancelation of what is on file first',
      v_label, CASE WHEN v_status = 'new' THEN 'a new customer' ELSE 'a winback' END;
  END IF;

  v_derived := public.rp_derive_sale_credits(v_sale_id);

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label,
                            'total_premium', v_derived->'total_premium',
                            'policies', jsonb_array_length(p->'products'),
                            'retention_points', v_derived->'retention_points',
                            'credits', v_derived->'credits');
END $function$;
