CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text; v_gnc boolean;
  v_sourced uuid; v_sale_id uuid; prod jsonb; v_lob text; v_type text; v_prem numeric;
  v_cnt integer; v_new boolean; v_veh integer; v_veh_total integer := 0;
  v_total numeric := 0; v_anchor text; v_ml_pts numeric; v_ref_pts numeric; v_credit_id uuid;
  v_credited text[] := ARRAY[]::text[];
  v_credits jsonb := '[]'::jsonb; v_rp numeric := 0; v_note text;
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
  v_sourced := COALESCE(NULLIF(p->>'sourced_by_team_member_id','')::uuid, a.team_member_id);
  IF NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;
  v_note := NULLIF(btrim(COALESCE(p->>'note','')),'');

  IF jsonb_typeof(p->'products') <> 'array' OR jsonb_array_length(p->'products') = 0 THEN
    RAISE EXCEPTION 'add at least one policy with its premium';
  END IF;
  IF jsonb_array_length(p->'products') > 40 THEN RAISE EXCEPTION 'more than 40 policies in one sale. Double-check it.'; END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(COALESCE(prod->>'line_of_business',''));
    IF v_lob NOT IN ('auto','fire','life','health','variable') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
    PERFORM public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'premium required for %', v_lob; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_lob; END IF;
    IF v_lob = 'auto' THEN
      v_veh := NULLIF(prod->>'vehicle_count','')::integer;
      IF v_veh IS NULL OR v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the auto policy?'; END IF;
      v_veh_total := v_veh_total + v_veh;
    END IF;
    v_total := v_total + v_prem;
  END LOOP;

  INSERT INTO public.sales_log (agency_id, team_member_id, sourced_by_team_member_id, submitted_date, issued_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_sourced, v_on, NULLIF(p->>'issued_date','')::date, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, v_gnc, NULLIF(v_veh_total, 0), v_total, v_note, a.actor_id)
  RETURNING id INTO v_sale_id;

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='multiline_sold' AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='referral_sold' AND is_active;

  IF v_status IN ('new','winback') THEN
    SELECT lower(x->>'line_of_business') INTO v_anchor
    FROM jsonb_array_elements(p->'products') x
    WHERE COALESCE((x->>'is_new_line')::boolean, true)
    ORDER BY NULLIF(x->>'premium','')::numeric DESC NULLS LAST, lower(x->>'line_of_business') LIMIT 1;
  END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(prod->>'line_of_business');
    v_type := public.rp_check_product_type(a.agency_id, v_lob, prod->>'product_type');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    v_cnt := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    v_new := COALESCE((prod->>'is_new_line')::boolean, true);
    v_veh := CASE WHEN v_lob = 'auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END;
    v_credit_id := NULL;
    IF v_new AND v_ml_pts IS NOT NULL AND NOT (v_lob = ANY (v_credited))
       AND (v_status = 'existing' OR v_lob IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
      VALUES (a.agency_id, v_sourced, 'multiline_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
        btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
        'From sale entry: ' || v_lob || ' added to household', v_ml_pts, 'sales_log', v_sale_id, a.actor_id)
      RETURNING id INTO v_credit_id;
      v_rp := v_rp + v_ml_pts;
      v_credited := v_credited || v_lob;
      v_credits := v_credits || jsonb_build_object('activity_key','multiline_sold','line',v_lob,'points',v_ml_pts);
    END IF;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, multiline_credit_id)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_credit_id);
  END LOOP;

  IF v_src = 'referral' AND v_status IN ('new','winback') AND v_ref_pts IS NOT NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
    VALUES (a.agency_id, v_sourced, 'referral_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
      btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
      'From sale entry: referral became a new household', v_ref_pts, 'sales_log', v_sale_id, a.actor_id);
    v_rp := v_rp + v_ref_pts;
    v_credits := v_credits || jsonb_build_object('activity_key','referral_sold','points',v_ref_pts);
  END IF;

  RETURN jsonb_build_object('ok', true, 'sale_id', v_sale_id, 'customer', v_label, 'total_premium', v_total,
                            'policies', jsonb_array_length(p->'products'),
                            'retention_points', v_rp, 'credits', v_credits, 'sourced_by', v_sourced);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_prem numeric; v_veh integer; v_id uuid; r RECORD; v_pref uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'canceled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancelation date cannot be in the future'; END IF;
  IF v_on < v_today - 90 THEN RAISE EXCEPTION 'log a cancelation within 90 days of the date it happened'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable') THEN
    RAISE EXCEPTION 'pick the policy line that canceled';
  END IF;
  v_type := public.rp_check_product_type(a.agency_id, v_line, p->>'product_type');
  v_prem := NULLIF(p->>'premium','')::numeric;
  IF v_prem IS NOT NULL AND v_prem < 0 THEN RAISE EXCEPTION 'premium cannot be negative'; END IF;
  IF v_prem IS NOT NULL AND v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_line; END IF;
  v_veh := CASE WHEN v_line = 'auto' THEN NULLIF(p->>'vehicle_count','')::integer ELSE NULL END;
  IF v_veh IS NOT NULL AND v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the canceled auto policy?'; END IF;
  v_reason := NULLIF(btrim(COALESCE(p->>'reason','')), '');
  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');
  v_pref := NULLIF(p->>'matched_sale_product_id','')::uuid;
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial,
     customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     upper(btrim(p->>'customer_last_initial')), v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref)
  RETURNING id INTO v_id;
  SELECT c.saves_voided, c.matched_sale_product_id, c.chargeback_points, c.window_fraction_left, s.submitted_date
    INTO r FROM public.cancelation_log c
    LEFT JOIN public.sales_log_products sp ON sp.id = c.matched_sale_product_id
    LEFT JOIN public.sales_log s ON s.id = sp.sales_log_id
   WHERE c.id = v_id;
  RETURN jsonb_build_object('ok', true, 'cancelation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'product_type', v_type, 'premium', v_prem, 'vehicle_count', v_veh,
                            'saves_voided', r.saves_voided, 'matched_submitted_date', r.submitted_date,
                            'chargeback_points', r.chargeback_points, 'window_fraction_left', r.window_fraction_left);
END $function$;
