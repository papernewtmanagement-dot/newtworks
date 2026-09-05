-- What a customer has on file, for the entry page: their active sold policies.
-- Used when a policy is marked Canceled, to show the premium we recorded and
-- prefill it (the logger can change it or fill it in when nothing is on file).
CREATE OR REPLACE FUNCTION public.rp_sold_on_file(p_customer_first text, p_customer_last_initial text)
 RETURNS TABLE(sale_product_id uuid, sale_id uuid, sale_date date, line_of_business text, product_type text,
               premium numeric, vehicle_count integer, already_canceled boolean, window_end date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT p.id, s.id, s.sale_date, p.line_of_business, p.product_type, p.premium, p.vehicle_count,
         EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active'),
         (s.sale_date + (public.rp_chargeback_window_months(p.line_of_business) || ' months')::interval)::date
  FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id
  JOIN public.sales_log_products p ON p.sales_log_id = s.id
  WHERE auth.uid() IS NOT NULL AND s.status = 'active'
    AND s.customer_label = public.rp_customer_label(p_customer_first, p_customer_last_initial)
  ORDER BY s.sale_date DESC, p.line_of_business;
$function$;
REVOKE ALL ON FUNCTION public.rp_sold_on_file(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_sold_on_file(text, text) TO authenticated;

-- The page can name the sold policy it showed the logger; the chargeback
-- trigger uses that one when it is valid, otherwise it searches as before.
CREATE OR REPLACE FUNCTION public.cancelation_log_chargeback()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp RECORD; cr RECORD; v_window_end date; v_left numeric; v_pts numeric; v_id uuid;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
BEGIN
  IF NEW.matched_sale_product_id IS NOT NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.sale_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = NEW.matched_sale_product_id AND s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = NEW.customer_label AND p.line_of_business = NEW.policy_line
       AND s.sale_date <= NEW.canceled_on
       AND s.sale_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on;
  END IF;
  IF sp.id IS NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.sale_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = NEW.customer_label AND p.line_of_business = NEW.policy_line
       AND s.sale_date <= NEW.canceled_on
       AND s.sale_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active' AND c.id <> NEW.id)
     ORDER BY (p.product_type IS NOT DISTINCT FROM NEW.product_type) DESC, s.sale_date DESC
     LIMIT 1;
  END IF;
  IF sp.id IS NULL THEN
    UPDATE public.cancelation_log SET matched_sale_product_id = NULL WHERE id = NEW.id AND matched_sale_product_id IS NOT NULL;
    RETURN NEW;
  END IF;

  v_window_end := (sp.sale_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval)::date;
  v_left := round((v_window_end - NEW.canceled_on)::numeric / NULLIF((v_window_end - sp.sale_date)::numeric, 0), 4);
  v_left := LEAST(1, GREATEST(0, COALESCE(v_left, 0)));
  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

  IF sp.multiline_credit_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO cr FROM public.retention_activity_log WHERE id = sp.multiline_credit_id AND status = 'credited';
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_pts := round(cr.points * v_left, 2);
  IF v_pts <= 0 THEN RETURN NEW; END IF;

  IF cr.credited_week_end_date >= v_cur_week THEN
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(), voided_by = NEW.created_by,
           void_reason = 'policy canceled ' || NEW.canceled_on::text || ' inside the chargeback window', updated_at = now()
     WHERE id = cr.id;
    UPDATE public.cancelation_log SET chargeback_points = cr.points, chargeback_activity_id = cr.id WHERE id = NEW.id;
  ELSE
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, note, points, source, source_id, created_by)
    VALUES (NEW.agency_id, cr.team_member_id, 'multiline_chargeback', NEW.canceled_on, public.rp_week_end(NEW.canceled_on), v_cur_week,
      NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_label,
      'Chargeback: ' || NEW.policy_line || ' sold ' || to_char(sp.sale_date, 'Mon FMDD') || ' canceled ' || to_char(NEW.canceled_on, 'Mon FMDD') ||
        ', ' || round(v_left * 100) || '% of the window left',
      -v_pts, 'cancelation_log', NEW.id, NEW.created_by)
    RETURNING id INTO v_id;
    UPDATE public.cancelation_log SET chargeback_points = v_pts, chargeback_activity_id = v_id WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

-- rp_log_cancelation passes the page's pick through (column preset before insert).
CREATE OR REPLACE FUNCTION public.rp_log_cancelation(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
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
  SELECT c.saves_voided, c.matched_sale_product_id, c.chargeback_points, c.window_fraction_left, s.sale_date
    INTO r FROM public.cancelation_log c
    LEFT JOIN public.sales_log_products sp ON sp.id = c.matched_sale_product_id
    LEFT JOIN public.sales_log s ON s.id = sp.sales_log_id
   WHERE c.id = v_id;
  RETURN jsonb_build_object('ok', true, 'cancelation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'product_type', v_type, 'premium', v_prem, 'vehicle_count', v_veh,
                            'saves_voided', r.saves_voided, 'matched_sale_date', r.sale_date,
                            'chargeback_points', r.chargeback_points, 'window_fraction_left', r.window_fraction_left);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_log_entry(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
  v_gnc    text  := NULLIF(p->>'gnc_used', '');
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
    'marketing_source', v_src, 'gnc_used', v_gnc, 'sourced_by_team_member_id', v_srcby);
  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.'; END IF;
      FOR i IN 1..v_cnt LOOP v_items := v_items || (it - 'count'); END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm);
  END IF;
  IF v_quote IS NOT NULL THEN r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on)); END IF;
  IF v_sale IS NOT NULL THEN r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('sale_date', v_on)); END IF;
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
