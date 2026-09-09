CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_url text; v_id uuid;
  v_items jsonb := '[]'::jsonb; it jsonb; v_line text; v_type text;
  v_lines text[]; v_rel text; v_existing boolean; v_src text; v_gnc boolean; v_sourced uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');

  IF jsonb_typeof(p->'items') = 'array' AND jsonb_array_length(p->'items') > 0 THEN
    v_items := p->'items';
  ELSIF jsonb_typeof(p->'products_discussed') = 'array' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('line_of_business', lower(e))), '[]'::jsonb)
      INTO v_items FROM jsonb_array_elements_text(p->'products_discussed') e;
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN RAISE EXCEPTION 'click every product you discussed. At least one.'; END IF;
  IF jsonb_array_length(v_items) > 40 THEN RAISE EXCEPTION 'more than 40 quoted policies in one entry. Double-check it.'; END IF;

  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;
  v_rel := NULLIF(lower(btrim(COALESCE(p->>'relationship_type',''))),'');
  IF v_rel IS NOT NULL AND v_rel NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'relationship type must be new, existing, or winback';
  END IF;
  v_existing := CASE WHEN v_rel IS NOT NULL THEN v_rel = 'existing'
                     ELSE COALESCE((p->>'is_existing_customer')::boolean, false) END;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'unknown marketing source';
  END IF;
  v_gnc := CASE WHEN NULLIF(p->>'gnc_used','') IS NULL THEN NULL ELSE (p->>'gnc_used')::boolean END;
  v_sourced := NULLIF(p->>'sourced_by_team_member_id','')::uuid;
  IF v_sourced IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(COALESCE(it->>'line_of_business','')));
    IF v_line NOT IN ('auto','fire','life','health','variable') THEN RAISE EXCEPTION 'unknown product: %', v_line; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
  END LOOP;
  SELECT array_agg(DISTINCT lower(x->>'line_of_business')) INTO v_lines FROM jsonb_array_elements(v_items) x;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_label,
    is_existing_customer, relationship_type, marketing_source, gnc_used, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
    v_existing, v_rel, v_src, v_gnc, v_sourced, v_url, v_lines, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
  RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(it->>'line_of_business'));
    v_type := public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
    INSERT INTO public.quote_log_products (quote_log_id, agency_id, line_of_business, product_type)
    VALUES (v_id, a.agency_id, v_line, v_type);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'quote_id', v_id, 'customer', v_label,
                            'products_discussed', to_jsonb(v_lines), 'policies', jsonb_array_length(v_items),
                            'relationship_type', v_rel, 'marketing_source', v_src);
END $function$;
