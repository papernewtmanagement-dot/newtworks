-- ===== the four remove functions now share one permission rule =====
CREATE OR REPLACE FUNCTION public.rp_void_sale(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  UPDATE public.sales_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now() WHERE id=p_id;
  UPDATE public.retention_activity_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason='sale entry removed', updated_at=now()
   WHERE source='sales_log' AND source_id=p_id AND status='credited';
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_void_quote(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.quote_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  UPDATE public.quote_log SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now() WHERE id=p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_void_activity(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — remove the sale instead'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  UPDATE public.retention_activity_log
     SET status='void', voided_at=now(), voided_by=a.actor_id, void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_void_cancelation(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.cancelation_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  UPDATE public.cancelation_log SET status='void', voided_at=now(), voided_by=a.actor_id,
         void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now() WHERE id=p_id;
  -- the chargeback it caused comes back off
  IF r.chargeback_activity_id IS NOT NULL THEN
    UPDATE public.retention_activity_log
       SET status = CASE WHEN activity_key = 'multiline_chargeback' THEN 'void' ELSE 'credited' END,
           voided_at = CASE WHEN activity_key = 'multiline_chargeback' THEN now() ELSE NULL END,
           voided_by  = CASE WHEN activity_key = 'multiline_chargeback' THEN a.actor_id ELSE NULL END,
           void_reason = CASE WHEN activity_key = 'multiline_chargeback' THEN 'cancelation removed' ELSE NULL END,
           updated_at = now()
     WHERE id = r.chargeback_activity_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

-- ===== one entry point the page calls to remove anything =====
CREATE OR REPLACE FUNCTION public.rp_delete_record(p_kind text, p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_kind text := lower(btrim(COALESCE(p_kind, '')));
BEGIN
  IF v_kind = 'sale'        THEN RETURN public.rp_void_sale(p_id, p_reason); END IF;
  IF v_kind = 'quote'       THEN RETURN public.rp_void_quote(p_id, p_reason); END IF;
  IF v_kind = 'activity'    THEN RETURN public.rp_void_activity(p_id, p_reason); END IF;
  IF v_kind = 'cancelation' THEN RETURN public.rp_void_cancelation(p_id, p_reason); END IF;
  IF v_kind = 'scorecard'   THEN
    SELECT * INTO r FROM public.fit_scorecards WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, public.rp_week_end(r.scorecard_date), r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    DELETE FROM public.fit_scorecards WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;
  RAISE EXCEPTION 'unknown record type: %', p_kind;
END $function$;

-- ===== edits, one function per record type =====
CREATE OR REPLACE FUNCTION public.rp_edit_sale(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
  v_today date := public.rp_today_central(); v_on date; prod jsonb; v_keep uuid[] := ARRAY[]::uuid[];
  v_pid uuid; v_lob text; v_type text; v_blocked text;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that sale was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_on := COALESCE(NULLIF(c->>'submitted_date','')::date, r.submitted_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;

  IF c ? 'household_status' AND lower(COALESCE(c->>'household_status','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'ecrm_opportunity_url' AND COALESCE(c->>'ecrm_opportunity_url','') !~* '^https?://' THEN
    RAISE EXCEPTION 'the ECRM opportunity link must start with http';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
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
    ecrm_opportunity_url  = CASE WHEN c ? 'ecrm_opportunity_url' THEN btrim(c->>'ecrm_opportunity_url') ELSE ecrm_opportunity_url END,
    marketing_source      = CASE WHEN c ? 'marketing_source' THEN c->>'marketing_source' ELSE marketing_source END,
    sourced_by_team_member_id = CASE WHEN c ? 'sourced_by_team_member_id' THEN NULLIF(c->>'sourced_by_team_member_id','')::uuid ELSE sourced_by_team_member_id END,
    gnc_used              = CASE WHEN c ? 'gnc_used' THEN (c->>'gnc_used')::boolean ELSE gnc_used END,
    note                  = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
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
      v_lob  := lower(prod->>'line_of_business');
      v_type := public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
      v_pid  := NULLIF(prod->>'id','')::uuid;
      IF v_pid IS NULL THEN
        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, issued_date, issued_premium, autopay_enrolled)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,
                GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
                CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
                COALESCE((prod->>'is_new_line')::boolean, true),
                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false));
      ELSE
        UPDATE public.sales_log_products SET
          line_of_business = v_lob, product_type = v_type,
          premium = NULLIF(prod->>'premium','')::numeric,
          policy_count = GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
          vehicle_count = CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
          is_new_line = COALESCE((prod->>'is_new_line')::boolean, is_new_line),
          issued_date = CASE WHEN prod ? 'issued_date' THEN NULLIF(prod->>'issued_date','')::date ELSE issued_date END,
          issued_premium = CASE WHEN prod ? 'issued_premium' THEN NULLIF(prod->>'issued_premium','')::numeric ELSE issued_premium END,
          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END
        WHERE id = v_pid AND sales_log_id = p_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id, 'derived', public.rp_derive_sale_credits(p_id));
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_quote(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
    gnc_used              = CASE WHEN c ? 'gnc_used' THEN (c->>'gnc_used')::boolean ELSE gnc_used END,
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

CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date;
BEGIN
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'that entry was removed. Log it again instead.'; END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — change the sale instead'; END IF;
  IF c ? 'activity_key' AND c->>'activity_key' IS DISTINCT FROM r.activity_key THEN
    RAISE EXCEPTION 'to change which activity it was, remove this one and log the right one';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.retention_activity_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    occurred_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    credited_week_end_date = CASE WHEN credited_week_end_date IS NULL THEN NULL ELSE public.rp_week_end(v_on) END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    policy_line  = CASE WHEN c ? 'policy_line'  THEN NULLIF(lower(btrim(COALESCE(c->>'policy_line',''))),'') ELSE policy_line END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_cancelation(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
BEGIN
  SELECT * INTO r FROM public.cancelation_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that cancelation was removed. Log it again instead.'; END IF;
  IF (c ? 'canceled_on' AND NULLIF(c->>'canceled_on','')::date IS DISTINCT FROM r.canceled_on)
     OR (c ? 'policy_line' AND lower(c->>'policy_line') IS DISTINCT FROM r.policy_line) THEN
    RAISE EXCEPTION 'to change the cancelation date or the policy line, remove this one and log it again — the chargeback is worked out from both';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  UPDATE public.cancelation_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4  = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    vehicle_count= CASE WHEN c ? 'vehicle_count' THEN NULLIF(c->>'vehicle_count','')::integer ELSE vehicle_count END,
    reason       = CASE WHEN c ? 'reason' THEN NULLIF(btrim(COALESCE(c->>'reason','')),'') ELSE reason END,
    note         = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at   = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_scorecard(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date;
BEGIN
  SELECT * INTO r FROM public.fit_scorecards WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, public.rp_week_end(r.scorecard_date), r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_on := COALESCE(NULLIF(c->>'scorecard_date','')::date, r.scorecard_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;

  UPDATE public.fit_scorecards SET
    scorecard_date = v_on,
    customer_first_name = CASE WHEN c ? 'customer_first_name' THEN btrim(c->>'customer_first_name') ELSE customer_first_name END,
    opportunity_ref     = CASE WHEN c ? 'opportunity_ref' THEN NULLIF(btrim(COALESCE(c->>'opportunity_ref','')),'') ELSE opportunity_ref END,
    demeanor_score        = CASE WHEN c ? 'demeanor_score'        THEN NULLIF(c->>'demeanor_score','')::integer        ELSE demeanor_score END,
    frogs_score           = CASE WHEN c ? 'frogs_score'           THEN NULLIF(c->>'frogs_score','')::integer           ELSE frogs_score END,
    intro_score           = CASE WHEN c ? 'intro_score'           THEN NULLIF(c->>'intro_score','')::integer           ELSE intro_score END,
    eligibility_score     = CASE WHEN c ? 'eligibility_score'     THEN NULLIF(c->>'eligibility_score','')::integer     ELSE eligibility_score END,
    setup_gnc_score       = CASE WHEN c ? 'setup_gnc_score'       THEN NULLIF(c->>'setup_gnc_score','')::integer       ELSE setup_gnc_score END,
    uncover_gap_score     = CASE WHEN c ? 'uncover_gap_score'     THEN NULLIF(c->>'uncover_gap_score','')::integer     ELSE uncover_gap_score END,
    bridge_gap_score      = CASE WHEN c ? 'bridge_gap_score'      THEN NULLIF(c->>'bridge_gap_score','')::integer      ELSE bridge_gap_score END,
    customize_close_score = CASE WHEN c ? 'customize_close_score' THEN NULLIF(c->>'customize_close_score','')::integer ELSE customize_close_score END,
    set_followup_score    = CASE WHEN c ? 'set_followup_score'    THEN NULLIF(c->>'set_followup_score','')::integer    ELSE set_followup_score END,
    review_referral_score = CASE WHEN c ? 'review_referral_score' THEN NULLIF(c->>'review_referral_score','')::integer ELSE review_referral_score END,
    recording_turned_in   = CASE WHEN c ? 'recording_turned_in'   THEN (c->>'recording_turned_in')::boolean ELSE recording_turned_in END,
    recording_url         = CASE WHEN c ? 'recording_url'         THEN NULLIF(btrim(COALESCE(c->>'recording_url','')),'') ELSE recording_url END,
    notes                 = CASE WHEN c ? 'notes' THEN NULLIF(btrim(COALESCE(c->>'notes','')),'') ELSE notes END,
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_delete_record(text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_sale(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_quote(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_activity(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_cancelation(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_scorecard(uuid, jsonb) TO authenticated;
