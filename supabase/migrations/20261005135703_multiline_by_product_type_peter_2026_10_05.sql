CREATE OR REPLACE FUNCTION public.rp_derive_sale_credits(p_sale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s RECORD; pr RECORD; v_ml_pts numeric; v_ref_pts numeric; v_anchor text; v_anchor_id uuid; v_any boolean; v_key text;
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

  /* Peter 2026-10-05: multiline means a household setting up more TYPES of products. Per product:
     - same product already on file -> no credit (an auto is an added auto; PLUP/PAP and a life on
       file in the last 60 days are replacements; other fire was asked replaces or added). A new
       life past the 60 days is a new product.
     - we hold records for the household -> any product it does not have is a multiline.
     - no records, New or Winback -> every product past the first.
     - no records, Existing -> the team said whether it is new or a replacement (is_new_line).
     One credit per product type per sale. */
  v_any := public.rp_household_on_file(p_sale_id);
  IF s.household_status IN ('new', 'winback') AND NOT v_any THEN
    SELECT p.id INTO v_anchor_id FROM public.sales_log_products p
     WHERE p.sales_log_id = p_sale_id AND NOT COALESCE(p.is_added_to_existing, false)
     ORDER BY p.premium DESC NULLS LAST, p.line_of_business, p.product_type LIMIT 1;
  END IF;

  FOR pr IN SELECT * FROM public.sales_log_products WHERE sales_log_id = p_sale_id ORDER BY created_at, id LOOP
    v_key := pr.line_of_business || ':' || COALESCE(pr.product_type, '');
    IF v_ml_pts IS NOT NULL AND NOT COALESCE(pr.is_added_to_existing, false)
       AND NOT (v_key = ANY (v_credited))
       AND NOT public.rp_household_on_file(p_sale_id, pr.id)
       AND (CASE WHEN v_any THEN true
                 WHEN s.household_status IN ('new', 'winback') THEN pr.id IS DISTINCT FROM v_anchor_id
                 ELSE COALESCE(pr.is_new_line, false) END) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url, note, points, source, source_id, created_by)
      VALUES (s.agency_id, s.team_member_id, 'multiline_sold', s.submitted_date,
        public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
        s.customer_first_name, s.customer_last_initial, s.customer_kind, s.phone_last4, s.ecrm_opportunity_url,
        'From sale entry: ' || COALESCE((SELECT pt.label FROM public.product_types pt WHERE pt.agency_id = s.agency_id
           AND pt.line_of_business = pr.line_of_business AND pt.type_key = pr.product_type), initcap(pr.line_of_business))
          || ' added to household', v_ml_pts, 'sales_log', p_sale_id, s.created_by)
      RETURNING id INTO v_credit_id;
      UPDATE public.sales_log_products SET multiline_credit_id = v_credit_id WHERE id = pr.id;
      v_rp := v_rp + v_ml_pts;
      v_credited := v_credited || v_key;
      v_credits := v_credits || jsonb_build_object('activity_key', 'multiline_sold', 'line', pr.line_of_business, 'product_type', pr.product_type, 'points', v_ml_pts);
    END IF;
  END LOOP;

  IF s.marketing_source = 'referral' AND s.household_status IN ('new', 'winback') AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url, note, points, source, source_id, created_by)
    VALUES (s.agency_id, s.team_member_id, 'referral_sold', s.submitted_date,
      public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
      s.customer_first_name, s.customer_last_initial, s.customer_kind, s.phone_last4, s.ecrm_opportunity_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', p_sale_id, s.created_by);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key', 'referral_sold', 'points', v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'total_premium', v_total, 'retention_points', v_rp, 'credits', v_credits);
END $function$;
