-- Every write path reads the person/organization toggle off the payload, hands
-- it to the one label builder, and stores it. Nothing builds a label by hand.

DROP FUNCTION IF EXISTS public.rp_log_activity(jsonb, text, text, date, text, text, uuid);

CREATE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid, p_customer_kind text DEFAULT 'person')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text; v_type text;
  v_credit_on date; v_credit_week date; v_id uuid;
  v_created jsonb := '[]'::jsonb; v_total numeric := 0; v_note text; v_url text;
  v_kind text := public.rp_customer_kind(p_customer_kind);
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial, v_kind);
  v_note := NULLIF(btrim(COALESCE(p_note,'')), '');
  v_url  := NULLIF(btrim(COALESCE(p_ecrm_url,'')), '');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_key := item->>'activity_key';
    SELECT * INTO v FROM public.retention_point_values
    WHERE agency_id = a.agency_id AND activity_key = v_key AND is_active AND category = 'logged';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown or not-loggable item: %', v_key; END IF;
    IF v.requires_note AND v_note IS NULL AND NULLIF(btrim(COALESCE(item->>'save_reason','')),'') IS NULL THEN
      RAISE EXCEPTION '% needs a note on what you covered / the reason', v.label;
    END IF;
    IF v.requires_ecrm AND v_url IS NULL THEN
      RAISE EXCEPTION '% needs the ECRM link so it can be checked', v.label;
    END IF;
    IF v.requires_platform AND NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NULL THEN
      RAISE EXCEPTION '% needs the site it was left on: Google, Facebook or Yelp', v.label;
    END IF;
    IF NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NOT NULL
       AND lower(btrim(item->>'review_platform')) NOT IN ('google', 'facebook', 'yelp') THEN
      RAISE EXCEPTION 'the review site has to be Google, Facebook or Yelp';
    END IF;
    -- Peter 2026-09-15: a save is credited per POLICY, so several saves for the
    -- same household on the same day are normal. Same reason autopay is exempt.
    IF v_key NOT IN ('autopay_enrollment', 'cancelation_saved') AND EXISTS (SELECT 1 FROM public.retention_activity_log l
               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id
                 AND l.activity_key = v_key AND l.customer_label = v_label AND l.occurred_on = v_on
                 AND l.status = 'credited' AND l.created_at < now()) THEN
      RAISE EXCEPTION '% for % is already logged for %. Use Undo or remove the first one if that was a mistake.',
        v.label, v_label, CASE WHEN v_on = v_today THEN 'today' ELSE to_char(v_on, 'Mon FMDD') END;
    END IF;

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL; v_type := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      v_type   := NULLIF(btrim(COALESCE(item->>'product_type','')), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      -- The unit is one policy. Line alone cannot tell two auto policies in the
      -- same household apart, so the type is required wherever the line has types.
      IF v_type IS NULL AND EXISTS (SELECT 1 FROM public.product_types pt
                                     WHERE pt.agency_id = a.agency_id AND pt.line_of_business = v_line) THEN
        RAISE EXCEPTION 'a save needs the policy type that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line
                   AND COALESCE(l.product_type, '') = COALESCE(v_type, '')
                   AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, COALESCE(v_type, v_line);
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_kind, customer_label, ecrm_url, note, save_reason, save_line, points, source, created_by, policy_line, product_type, premium, review_platform)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), public.rp_customer_initial(p_customer_last_initial, v_kind), v_kind, v_label, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id,
       NULLIF(lower(btrim(COALESCE(item->>'policy_line',''))), ''), NULLIF(btrim(COALESCE(item->>'product_type','')), ''), NULLIF(item->>'premium','')::numeric, NULLIF(lower(btrim(COALESCE(item->>'review_platform',''))), ''))
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_log_activity(jsonb, text, text, date, text, text, uuid, text) TO authenticated, service_role;


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
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);

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

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_kind, customer_label,
    is_existing_customer, relationship_type, marketing_source, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_label,
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
    customer_first_name, customer_last_initial, customer_kind, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, vehicle_count, total_premium, note, created_by, on_file_answer, replaced_sale_product_id)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_label, v_status, v_url,
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


CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_type text; v_reason text; v_note text;
  v_prem numeric; v_veh integer; v_id uuid; r RECORD; v_pref uuid; v_ecrm text;
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'canceled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancelation date cannot be in the future'; END IF;
  IF v_on < v_today - 90 THEN RAISE EXCEPTION 'log a cancelation within 90 days of the date it happened'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial', v_kind);
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable','bank') THEN
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
  v_ecrm := NULLIF(btrim(COALESCE(p->>'ecrm_url','')), '');
  IF v_ecrm IS NULL THEN RAISE EXCEPTION 'a cancelation needs the ECRM link'; END IF;
  IF v_ecrm !~* '^https?://' THEN RAISE EXCEPTION 'the ECRM link must start with http'; END IF;
  INSERT INTO public.cancelation_log
    (agency_id, team_member_id, canceled_on, week_end_date, customer_first_name, customer_last_initial, customer_kind,
     customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement, ecrm_url)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'),
     public.rp_customer_initial(p->>'customer_last_initial', v_kind), v_kind, v_label, v_line, v_type, v_prem, v_veh, v_reason, v_note, a.actor_id, v_pref, COALESCE((p->>'replacement')::boolean, false), v_ecrm)
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


CREATE OR REPLACE FUNCTION public.rp_log_appointment(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_on date := COALESCE(NULLIF(p->>'set_on','')::date, public.rp_today_central());
  v_to uuid := NULLIF(p->>'escalated_to_team_member_id','')::uuid;
  v_first text := btrim(COALESCE(p->>'customer_first',''));
  v_kind text := public.rp_customer_kind(p->>'customer_kind');
  v_init  text := public.rp_customer_initial(p->>'customer_last_initial', v_kind);
  v_lob  text := lower(btrim(COALESCE(p->>'line_of_business','')));
  v_type text := NULLIF(btrim(COALESCE(p->>'product_type','')),'');
  v_starts timestamptz := NULLIF(p->>'starts_at','')::timestamptz;
  v_mins int := GREATEST(15, LEAST(240, COALESCE(NULLIF(p->>'duration_minutes','')::int, 30)));
  v_video boolean := COALESCE((p->>'is_video')::boolean, false);
  v_label text; v_where text; v_cal jsonb; v_id uuid;
  OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_first = '' THEN RAISE EXCEPTION 'who is the appointment with'; END IF;
  IF regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
    RAISE EXCEPTION 'what product is the appointment about?';
  END IF;
  PERFORM public.rp_check_product_type(a.agency_id, v_lob, v_type);
  IF v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;

  v_label := public.rp_customer_label(v_first, v_init, v_kind);
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_kind, customer_label, phone_last4,
    line_of_business, product_type, starts_at, duration_minutes, is_video, location,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init, v_kind, v_label,
    regexp_replace(p->>'phone_last4','\D','','g'), v_lob, v_type,
    v_starts, v_mins, v_video, v_where,
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;

  v_cal := public.rp_appointment_sync_calendar(v_id);
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', v_label) || v_cal;
END $function$;


CREATE OR REPLACE FUNCTION public.rp_log_entry(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p        jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_first  text  := p->>'customer_first';
  v_kind   text  := public.rp_customer_kind(p->>'customer_kind');
  v_init   text  := public.rp_customer_initial(p->>'customer_last_initial', v_kind);
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
    'customer_first', v_first, 'customer_last_initial', v_init, 'customer_kind', v_kind,
    'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm,
    'relationship_type', v_rel, 'household_status', v_rel,
    'marketing_source', v_src, 'sourced_by_team_member_id', v_srcby);
  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.'; END IF;
      FOR i IN 1..v_cnt LOOP v_items := v_items || (it - 'count'); END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm, v_kind);
  END IF;
  IF v_quote IS NOT NULL THEN r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on)); END IF;
  IF v_sale IS NOT NULL THEN r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('submitted_date', v_on)); END IF;
  IF v_cxl IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_cxl_items) LOOP
      r_one := public.rp_log_cancelation(jsonb_build_object(
        'customer_first', v_first, 'customer_last_initial', v_init, 'customer_kind', v_kind, 'canceled_on', v_on,
        'policy_line', it->>'line_of_business', 'product_type', it->>'product_type',
        'premium', it->>'premium', 'vehicle_count', it->>'vehicle_count',
        'matched_sale_product_id', it->>'matched_sale_product_id', 'ecrm_url', v_url,
        'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;
  IF v_card IS NOT NULL THEN r_card := public.rp_log_scorecard(v_shared || v_card || jsonb_build_object('scorecard_date', v_on)); END IF;
  RETURN jsonb_build_object('ok', true, 'customer', public.rp_customer_label(v_first, v_init, v_kind),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancelation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END, 'scorecard', r_card);
END $function$;
