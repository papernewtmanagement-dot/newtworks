-- Two changes to how a sale is logged.
-- 1. An auto line now says whether it is a brand new policy or a vehicle added
--    to a policy the household already has. An added vehicle is never a new line
--    of business, so it never earns a multiline credit.
-- 2. "Sourced by" is gone. The change log already records who entered a record
--    and who it belongs to, so the credits a sale earns go to the owner.

ALTER TABLE public.sales_log_products
  ADD COLUMN IF NOT EXISTS is_added_to_existing boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.sales_log_products.is_added_to_existing IS
  'Auto only. True when this is a vehicle added to a policy the household already has, rather than a new policy. Forces is_new_line false.';

COMMENT ON COLUMN public.sales_log.sourced_by_team_member_id IS
  'Retired 2026-09-15 (Peter). No longer written or read. Kept so history is not lost; drop it once the old rows are no longer wanted.';

-- Credits follow the owner of the sale, not a separate sourced-by field.
CREATE OR REPLACE FUNCTION public.rp_derive_sale_credits(p_sale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s RECORD; pr RECORD; v_ml_pts numeric; v_ref_pts numeric; v_anchor text;
  v_credited text[] := ARRAY[]::text[]; v_credits jsonb := '[]'::jsonb;
  v_rp numeric := 0; v_credit_id uuid; v_total numeric; v_veh integer; v_locked boolean;
BEGIN
  SELECT * INTO s FROM public.sales_log WHERE id = p_sale_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sale not found'; END IF;

  SELECT COALESCE(SUM(premium), 0), NULLIF(SUM(COALESCE(vehicle_count, 0)), 0)
    INTO v_total, v_veh
    FROM public.sales_log_products WHERE sales_log_id = p_sale_id;
  UPDATE public.sales_log SET total_premium = v_total, vehicle_count = v_veh, updated_at = now()
   WHERE id = p_sale_id
     AND (total_premium IS DISTINCT FROM v_total OR vehicle_count IS DISTINCT FROM v_veh);

  SELECT EXISTS (
    SELECT 1 FROM public.retention_activity_log l
     WHERE l.source = 'sales_log' AND l.source_id = p_sale_id
       AND l.activity_key IN ('multiline_sold', 'referral_sold')
       AND EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.chargeback_activity_id = l.id)
  ) INTO v_locked;

  IF v_locked OR COALESCE(s.entry_source, 'manual') <> 'manual' OR s.status <> 'active' THEN
    RETURN jsonb_build_object('ok', true, 'total_premium', v_total,
      'credits_locked', (v_locked OR COALESCE(s.entry_source,'manual') <> 'manual'),
      'retention_points', (SELECT COALESCE(SUM(points), 0) FROM public.retention_activity_log
        WHERE source = 'sales_log' AND source_id = p_sale_id AND activity_key IN ('multiline_sold','referral_sold')),
      'credits', '[]'::jsonb);
  END IF;

  UPDATE public.sales_log_products SET multiline_credit_id = NULL
   WHERE sales_log_id = p_sale_id AND multiline_credit_id IS NOT NULL;
  DELETE FROM public.retention_activity_log
   WHERE source = 'sales_log' AND source_id = p_sale_id
     AND activity_key IN ('multiline_sold', 'referral_sold');

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'multiline_sold'  AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'referral_sold' AND is_active;

  IF s.household_status IN ('new', 'winback') THEN
    SELECT p.line_of_business INTO v_anchor FROM public.sales_log_products p
     WHERE p.sales_log_id = p_sale_id AND COALESCE(p.is_new_line, true) AND NOT COALESCE(p.is_added_to_existing, false)
     ORDER BY p.premium DESC NULLS LAST, p.line_of_business LIMIT 1;
  END IF;

  FOR pr IN SELECT * FROM public.sales_log_products WHERE sales_log_id = p_sale_id ORDER BY created_at, id LOOP
    IF COALESCE(pr.is_new_line, true) AND NOT COALESCE(pr.is_added_to_existing, false) AND v_ml_pts IS NOT NULL
       AND NOT (pr.line_of_business = ANY (v_credited))
       AND (s.household_status = 'existing' OR pr.line_of_business IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, phone_last4, ecrm_url, note, points, source, source_id, created_by)
      VALUES (s.agency_id, s.team_member_id, 'multiline_sold', s.submitted_date,
        public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
        s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4, s.ecrm_opportunity_url,
        'From sale entry: ' || pr.line_of_business || ' added to household', v_ml_pts, 'sales_log', p_sale_id, s.created_by)
      RETURNING id INTO v_credit_id;
      UPDATE public.sales_log_products SET multiline_credit_id = v_credit_id WHERE id = pr.id;
      v_rp := v_rp + v_ml_pts;
      v_credited := v_credited || pr.line_of_business;
      v_credits := v_credits || jsonb_build_object('activity_key', 'multiline_sold', 'line', pr.line_of_business, 'points', v_ml_pts);
    END IF;
  END LOOP;

  IF s.marketing_source = 'referral' AND s.household_status IN ('new', 'winback') AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, phone_last4, ecrm_url, note, points, source, source_id, created_by)
    VALUES (s.agency_id, s.team_member_id, 'referral_sold', s.submitted_date,
      public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
      s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4, s.ecrm_opportunity_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', p_sale_id, s.created_by);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key', 'referral_sold', 'points', v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'total_premium', v_total, 'retention_points', v_rp, 'credits', v_credits);
END $function$;

-- Logging a sale: added-vehicle flag in, sourced-by out.
CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text; v_gnc boolean;
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
  IF p->>'gnc_used' IS NULL THEN RAISE EXCEPTION 'say whether Good Neighbor Connect was used'; END IF;
  v_gnc := (p->>'gnc_used')::boolean;
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
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, v_gnc, NULL, 0, v_note, a.actor_id, NULLIF(btrim(COALESCE(p->>'on_file_answer','')), ''), NULLIF(p->>'replaced_sale_product_id','')::uuid)
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

-- Editing a sale: same two changes.
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
    gnc_used              = CASE WHEN c ? 'gnc_used' THEN (c->>'gnc_used')::boolean ELSE gnc_used END,
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
