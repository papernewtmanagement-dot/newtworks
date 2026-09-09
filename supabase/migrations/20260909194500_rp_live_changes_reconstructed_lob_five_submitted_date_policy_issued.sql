-- Reconstructed 2026-09-09. These three functions and the dropped column were
-- changed directly against the live database and never recorded as a migration.
-- The function bodies below are read back out of the live database exactly as
-- they stand, so a rebuild from these files lands on production state.
--
-- What changed:
--   sales_log.issued_date  dropped. A policy is submitted and a policy issues;
--                          a sale does not issue separately. The issue date now
--                          lives only on sales_log_products.
--   rp_log_activity        allowed save lines are now auto/fire/life/health/variable.
--   rp_log_entry           passes submitted_date instead of sale_date to rp_log_sale.
--   rp_log_sale            no longer writes an issue date on the sale; it writes
--                          one per policy on sales_log_products instead.

ALTER TABLE public.sales_log DROP COLUMN IF EXISTS issued_date;

CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text;
  v_credit_on date; v_credit_week date; v_id uuid;
  v_created jsonb := '[]'::jsonb; v_total numeric := 0; v_note text; v_url text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial);
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
    IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id
                 AND l.activity_key = v_key AND l.customer_label = v_label AND l.occurred_on = v_on
                 AND l.status = 'credited' AND l.created_at < now()) THEN
      RAISE EXCEPTION '% for % is already logged for %. Use Undo or remove the first one if that was a mistake.',
        v.label, v_label, CASE WHEN v_on = v_today THEN 'today' ELSE to_char(v_on, 'Mon FMDD') END;
    END IF;

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same business day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, v_line;
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_label, ecrm_url, note, save_reason, save_line, points, source, created_by)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), upper(btrim(p_customer_last_initial)), v_label, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id)
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
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

  INSERT INTO public.sales_log (agency_id, team_member_id, sourced_by_team_member_id, submitted_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_sourced, v_on, public.rp_week_end(v_on),
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
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, multiline_credit_id, issued_date)
    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_credit_id, NULLIF(prod->>'issued_date','')::date);
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
