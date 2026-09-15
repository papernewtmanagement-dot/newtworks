-- One place decides who may change a Production record.
-- Admin: anything. Everyone else: their own, while the week is still open,
-- or anything they logged today.
CREATE OR REPLACE FUNCTION public.rp_guard_change(p_row_team_member_id uuid, p_week_end date, p_created_at timestamptz DEFAULT NULL)
RETURNS TABLE(actor_id uuid, team_member_id uuid, agency_id uuid, is_admin boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN
    IF p_row_team_member_id IS DISTINCT FROM a.actor_id THEN
      RAISE EXCEPTION 'you can only change your own entries' USING ERRCODE='42501';
    END IF;
    IF p_week_end < public.rp_week_end(public.rp_today_central())
       AND COALESCE(p_created_at, now()) < public.rp_today_central()::timestamptz THEN
      RAISE EXCEPTION 'that week is closed. Ask Peter to change it.' USING ERRCODE='42501';
    END IF;
  END IF;
  RETURN QUERY SELECT a.actor_id, a.team_member_id, a.agency_id, a.is_admin;
END $function$;

-- The ONLY thing that writes a sale's totals and its multiline / referral credits.
-- Called on log and on every edit, so both paths always agree.
CREATE OR REPLACE FUNCTION public.rp_derive_sale_credits(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s RECORD; pr RECORD; v_ml_pts numeric; v_ref_pts numeric; v_anchor text;
  v_credited text[] := ARRAY[]::text[]; v_credits jsonb := '[]'::jsonb;
  v_rp numeric := 0; v_credit_id uuid; v_total numeric; v_veh integer;
BEGIN
  SELECT * INTO s FROM public.sales_log WHERE id = p_sale_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'sale not found'; END IF;

  SELECT COALESCE(SUM(premium), 0), NULLIF(SUM(COALESCE(vehicle_count, 0)), 0)
    INTO v_total, v_veh
    FROM public.sales_log_products WHERE sales_log_id = p_sale_id;
  UPDATE public.sales_log SET total_premium = v_total, vehicle_count = v_veh, updated_at = now()
   WHERE id = p_sale_id
     AND (total_premium IS DISTINCT FROM v_total OR vehicle_count IS DISTINCT FROM v_veh);

  UPDATE public.sales_log_products SET multiline_credit_id = NULL
   WHERE sales_log_id = p_sale_id AND multiline_credit_id IS NOT NULL;
  DELETE FROM public.retention_activity_log
   WHERE source = 'sales_log' AND source_id = p_sale_id
     AND activity_key IN ('multiline_sold', 'referral_sold');

  IF s.status <> 'active' THEN
    RETURN jsonb_build_object('ok', true, 'total_premium', v_total, 'retention_points', 0, 'credits', '[]'::jsonb);
  END IF;

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'multiline_sold'  AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id = s.agency_id AND activity_key = 'referral_sold' AND is_active;

  IF s.household_status IN ('new', 'winback') THEN
    SELECT p.line_of_business INTO v_anchor FROM public.sales_log_products p
     WHERE p.sales_log_id = p_sale_id AND COALESCE(p.is_new_line, true)
     ORDER BY p.premium DESC NULLS LAST, p.line_of_business LIMIT 1;
  END IF;

  FOR pr IN SELECT * FROM public.sales_log_products WHERE sales_log_id = p_sale_id ORDER BY created_at, id LOOP
    IF COALESCE(pr.is_new_line, true) AND v_ml_pts IS NOT NULL
       AND NOT (pr.line_of_business = ANY (v_credited))
       AND (s.household_status = 'existing' OR pr.line_of_business IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, phone_last4, ecrm_url, note, points, source, source_id, created_by)
      VALUES (s.agency_id, s.sourced_by_team_member_id, 'multiline_sold', s.submitted_date,
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
    VALUES (s.agency_id, s.sourced_by_team_member_id, 'referral_sold', s.submitted_date,
      public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
      s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4, s.ecrm_opportunity_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', p_sale_id, s.created_by);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key', 'referral_sold', 'points', v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'total_premium', v_total, 'retention_points', v_rp, 'credits', v_credits);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_guard_change(uuid, date, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_derive_sale_credits(uuid) TO authenticated;
