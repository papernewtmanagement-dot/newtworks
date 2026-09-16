-- GNC is the Setup GNC score on the conversation scorecard (Peter 2026-09-11).
-- The gnc_used column on sales_log and quote_log was the old checkbox and is a
-- second place to hold the same fact. Dropped. Five functions and the
-- manual-entry check constraint stop referring to it first.

-- 1. sales_log manual-entry rule: ECRM link and marketing source only.
ALTER TABLE public.sales_log DROP CONSTRAINT IF EXISTS sales_log_manual_entry_required_fields;
ALTER TABLE public.sales_log ADD CONSTRAINT sales_log_manual_entry_required_fields
  CHECK ((entry_source <> 'manual') OR (ecrm_opportunity_url IS NOT NULL AND marketing_source IS NOT NULL));

-- 2. rp_log_sale
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
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'submitted_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;
  IF v_on < v_today - 30 THEN RAISE EXCEPTION 'log a sale within 30 days of the bind'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_status := lower(COALESCE(p->>'household_status',''));
  IF v_status NOT IN ('new','existing','winback') THEN RAISE EXCEPTION 'pick the relationship type: new, existing, or winback'; END IF;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NULL OR v_url !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM opportunity link is required (must start with http)'; END IF;
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NULL OR NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  v_note := NULLIF(btrim(COALESCE(p->>'note','')),'');

  IF jsonb_typeof(p->'products') <> 'array' OR jsonb_array_length(p->'products') = 0 THEN
    RAISE EXCEPTION 'add at least one policy with its premium';
  END IF;
  IF jsonb_array_length(p->'products') > 40 THEN RAISE EXCEPTION 'more than 40 policies in one sale. Double-check it.'; END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    PERFORM public.rp_check_sale_product(a.agency_id, prod);
  END LOOP;

  INSERT INTO public.sales_log (agency_id, team_member_id, submitted_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, NULL, 0, v_note, a.actor_id, NULLIF(btrim(COALESCE(p->>'on_file_answer','')), ''), NULLIF(p->>'replaced_sale_product_id','')::uuid)
  RETURNING id INTO v_sale_id;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob   := lower(prod->>'line_of_business');
    v_type  := public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem  := NULLIF(prod->>'premium','')::numeric;
    v_cnt   := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    v_added := (v_lob = 'auto' AND COALESCE((prod->>'added_to_existing')::boolean, false));
    -- a vehicle added to a policy they already have is not a new line
    v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
    v_veh   := CASE WHEN v_lob = 'auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, autopay_enrolled)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_added, NULLIF(prod->>'issued_date','')::date, COALESCE((prod->>'autopay')::boolean, false));
  END LOOP;

  v_derived := public.rp_derive_sale_credits(v_sale_id);

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label,
                            'total_premium', v_derived->'total_premium',
                            'policies', jsonb_array_length(p->'products'),
                            'retention_points', v_derived->'retention_points',
                            'credits', v_derived->'credits');
END $function$;

-- 3. rp_log_quote
CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_url text; v_id uuid;
  v_items jsonb := '[]'::jsonb; it jsonb; v_line text; v_type text;
  v_lines text[]; v_rel text; v_existing boolean; v_src text; v_sourced uuid;
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
  v_sourced := NULLIF(p->>'sourced_by_team_member_id','')::uuid;
  IF v_sourced IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_line := lower(btrim(COALESCE(it->>'line_of_business','')));
    IF v_line NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_line; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_line, it->>'product_type');
  END LOOP;
  SELECT array_agg(DISTINCT lower(x->>'line_of_business')) INTO v_lines FROM jsonb_array_elements(v_items) x;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_label,
    is_existing_customer, relationship_type, marketing_source, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
    v_existing, v_rel, v_src, v_sourced, v_url, v_lines, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
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

-- 4. rp_log_entry: the shared block no longer carries a GNC answer.
CREATE OR REPLACE FUNCTION public.rp_log_entry(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p        jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_first  text  := p->>'customer_first';
  v_init   text  := p->>'customer_last_initial';
  v_on     date  := NULLIF(p->>'occurred_on', '')::date;
  v_url    text  := NULLIF(btrim(COALESCE(p->>'ecrm_url', '')), '');
  v_note   text  := NULLIF(btrim(COALESCE(p->>'note', '')), '');
  v_tm     uuid  := NULLIF(p->>'team_member_id', '')::uuid;
  v_rel    text  := NULLIF(lower(btrim(COALESCE(p->>'relationship_type', ''))), '');
  v_src    text  := NULLIF(btrim(COALESCE(p->>'marketing_source', '')), '');
  v_srcby  text  := NULLIF(p->>'sourced_by_team_member_id', '');
  v_act    jsonb := p->'activity';
  v_quote  jsonb := p->'quote';
  v_sale   jsonb := p->'sale';
  v_cxl    jsonb := p->'cancelation';
  v_card   jsonb := p->'scorecard';
  v_cxl_items jsonb := '[]'::jsonb;
  v_items  jsonb := '[]'::jsonb;
  v_shared jsonb;
  it       jsonb;
  v_cnt    integer;
  i        integer;
  r_act    jsonb; r_quote jsonb; r_sale jsonb; r_cxl jsonb := '[]'::jsonb; r_one jsonb; r_card jsonb;
BEGIN
  -- customer phone, last four digits: required on every record, part of the household key (Peter 2026-09-11)
  IF regexp_replace(COALESCE(p_payload->>'phone_last4', ''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  PERFORM set_config('rp.phone_last4', regexp_replace(p_payload->>'phone_last4', '\D', '', 'g'), true);
  IF v_act IS NULL OR jsonb_typeof(v_act) <> 'object'
     OR jsonb_typeof(v_act->'items') <> 'array' OR jsonb_array_length(v_act->'items') = 0 THEN v_act := NULL; END IF;
  IF v_quote IS NULL OR jsonb_typeof(v_quote) <> 'object'
     OR jsonb_typeof(v_quote->'items') <> 'array' OR jsonb_array_length(v_quote->'items') = 0 THEN v_quote := NULL; END IF;
  IF v_sale IS NULL OR jsonb_typeof(v_sale) <> 'object'
     OR jsonb_typeof(v_sale->'products') <> 'array' OR jsonb_array_length(v_sale->'products') = 0 THEN v_sale := NULL; END IF;
  IF v_cxl IS NOT NULL AND jsonb_typeof(v_cxl) = 'object' AND jsonb_typeof(v_cxl->'items') = 'array' THEN v_cxl_items := v_cxl->'items'; END IF;
  IF jsonb_array_length(v_cxl_items) = 0 THEN v_cxl := NULL; END IF;
  IF jsonb_array_length(v_cxl_items) > 40 THEN RAISE EXCEPTION 'more than 40 canceled policies in one entry. Double-check it.'; END IF;
  IF v_card IS NULL OR jsonb_typeof(v_card) <> 'object' THEN v_card := NULL; END IF;
  IF v_act IS NULL AND v_quote IS NULL AND v_sale IS NULL AND v_cxl IS NULL AND v_card IS NULL THEN
    RAISE EXCEPTION 'add at least one thing to log: an activity, a policy, or a scorecard';
  END IF;
  IF v_sale IS NOT NULL AND v_cxl IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sale->'products') s JOIN jsonb_array_elements(v_cxl_items) c
               ON lower(btrim(COALESCE(s->>'line_of_business',''))) = lower(btrim(COALESCE(c->>'line_of_business','')))) THEN
      RAISE EXCEPTION 'a sale and a cancelation on the same policy line cannot go in one entry. Log them separately.';
    END IF;
  END IF;
  v_shared := jsonb_build_object(
    'customer_first', v_first, 'customer_last_initial', v_init,
    'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm,
    'relationship_type', v_rel, 'household_status', v_rel,
    'marketing_source', v_src, 'sourced_by_team_member_id', v_srcby);
  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.'; END IF;
      FOR i IN 1..v_cnt LOOP v_items := v_items || (it - 'count'); END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm);
  END IF;
  IF v_quote IS NOT NULL THEN r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on)); END IF;
  IF v_sale IS NOT NULL THEN r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('submitted_date', v_on)); END IF;
  IF v_cxl IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_cxl_items) LOOP
      r_one := public.rp_log_cancelation(jsonb_build_object(
        'customer_first', v_first, 'customer_last_initial', v_init, 'canceled_on', v_on,
        'policy_line', it->>'line_of_business', 'product_type', it->>'product_type',
        'premium', it->>'premium', 'vehicle_count', it->>'vehicle_count',
        'matched_sale_product_id', it->>'matched_sale_product_id',
        'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;
  IF v_card IS NOT NULL THEN r_card := public.rp_log_scorecard(v_shared || v_card || jsonb_build_object('scorecard_date', v_on)); END IF;
  RETURN jsonb_build_object('ok', true, 'customer', public.rp_customer_label(v_first, v_init),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancelation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END, 'scorecard', r_card);
END $function$;

-- 5. rp_edit_quote
CREATE OR REPLACE FUNCTION public.rp_edit_quote(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; prod jsonb; v_lob text;
BEGIN
  SELECT * INTO r FROM public.quote_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that quote was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_on := COALESCE(NULLIF(c->>'quote_date','')::date, r.quote_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF c ? 'relationship_type' AND lower(COALESCE(c->>'relationship_type','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.quote_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    quote_date            = v_on,
    week_end_date         = public.rp_week_end(v_on),
    relationship_type     = CASE WHEN c ? 'relationship_type' THEN lower(c->>'relationship_type') ELSE relationship_type END,
    marketing_source      = CASE WHEN c ? 'marketing_source' THEN c->>'marketing_source' ELSE marketing_source END,
    sourced_by_team_member_id = CASE WHEN c ? 'sourced_by_team_member_id' THEN NULLIF(c->>'sourced_by_team_member_id','')::uuid ELSE sourced_by_team_member_id END,
    ecrm_opportunity_url  = CASE WHEN c ? 'ecrm_opportunity_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_opportunity_url','')),'') ELSE ecrm_opportunity_url END,
    note                  = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at            = now()
  WHERE id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a quote needs at least one product';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob := lower(COALESCE(prod->>'line_of_business',''));
      IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
      PERFORM public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
    END LOOP;
    DELETE FROM public.quote_log_products WHERE quote_log_id = p_id;
    INSERT INTO public.quote_log_products (quote_log_id, agency_id, line_of_business, product_type)
    SELECT p_id, r.agency_id, lower(x->>'line_of_business'),
           public.rp_check_product_type(r.agency_id, lower(x->>'line_of_business'), x->>'product_type')
      FROM jsonb_array_elements(c->'products') x;
    UPDATE public.quote_log SET products_discussed = (
      SELECT array_agg(DISTINCT lower(x->>'line_of_business')) FROM jsonb_array_elements(c->'products') x
    ) WHERE id = p_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

-- 6. rp_edit_sale
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
  v_ecrm text; v_source text;
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
  v_source := NULLIF(COALESCE(NULLIF(c->>'marketing_source',''), r.marketing_source, ''), '');

  IF v_ecrm IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN v_was <> 'manual'
      THEN 'Moving this into the production log needs the ECRM opportunity link.'
      ELSE 'A sale needs the ECRM opportunity link.' END;
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

-- 7. The column itself, both tables.
ALTER TABLE public.sales_log DROP COLUMN IF EXISTS gnc_used;
ALTER TABLE public.quote_log DROP COLUMN IF EXISTS gnc_used;
