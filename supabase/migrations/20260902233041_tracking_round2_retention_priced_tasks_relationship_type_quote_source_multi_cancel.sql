-- Tracking entry page, round two (Peter 2026-09-02).
--
-- 1. Service tasks are priced on what they do for retention, not on effort.
--    Anchor: Multiline Sold at $10 is the strongest documented retention
--    driver (Reinartz & Kumar 2003, Journal of Marketing 67(1): customers who
--    buy across more categories have longer profitable lifetimes; switching
--    cost rises with each line). Everything in the service band sits well
--    under it.
--      Policy Change ........ 1.00  Kano 1984 must-be quality: a customer-
--                                   requested change keeps what they had. Done
--                                   right it adds no loyalty; not done, they go.
--      Manual COI ........... 1.50  Must-be quality on a commercial account. A
--                                   missed certificate is a core service failure
--                                   (Keaveney 1995, leading cause of switching),
--                                   so the avoided loss is real, but it builds
--                                   nothing.
--      Added Car ............ 2.00  Deepens share of wallet inside one line.
--                                   Depth within a category is a weaker signal
--                                   than breadth across categories (Reinartz &
--                                   Kumar 2003), so a fraction of Multiline. The
--                                   premium is paid by commission already.
--      Back Office Question . 2.50  Service recovery. An underwriting or billing
--                                   problem left alone becomes a lapse; resolving
--                                   it is a cancellation prevented upstream. Tax,
--                                   Brown & Chandrashekaran 1998: the recovery
--                                   experience outweighs cumulative prior
--                                   experience in forming trust and commitment.
--                                   A third of a Cancellation Saved because the
--                                   counterfactual is less certain.
--    The old "standard" tier is gone as a concept; its key (service_task) now
--    carries Policy Change so history keeps a sensible label.
--
-- 2. Relationship Type replaces Household and gains Winback. It applies to
--    quotes and sales both, so quote_log gets relationship_type (the old
--    is_existing_customer column stays and is filled from it).
--
-- 3. Marketing source and Good Neighbor Connect apply to quotes as well as
--    sales. Tracking only on the quote side: pays nothing.
--
-- 4. A cancellation entry can mark several products. One cancellation_log row
--    per product, so chargeback matching later stays per line.

-- ---------- 1. point values ----------
UPDATE public.retention_point_values
   SET label = 'Policy Change', points = 1.00, sort_order = 40, updated_at = now(),
       description = 'A change the customer asked for on a policy they already have: added or changed driver, replacement vehicle, address, coverage. Taking a payment or sending ID cards is part of answering the call, not a task.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task';

INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'service_task_added_car', 'Added Car', 2.00, 'logged', false, 41, true,
        'A vehicle added to an auto policy already in force. More of the household''s cars with us means more to move if they ever leave. Not a new line, so no multiline credit.')
ON CONFLICT (agency_id, activity_key) DO UPDATE
   SET label = EXCLUDED.label, points = EXCLUDED.points, sort_order = EXCLUDED.sort_order,
       description = EXCLUDED.description, is_active = true, updated_at = now();

UPDATE public.retention_point_values
   SET label = 'Back Office Question', points = 2.50, sort_order = 42, updated_at = now(),
       description = 'An underwriting or billing problem you chased on the company side until it was resolved, so the policy stayed in force. Counts when it is resolved, not when it is started.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task_company';

UPDATE public.retention_point_values
   SET label = 'Manual COI', points = 1.50, sort_order = 43, updated_at = now(),
       description = 'A certificate of insurance you built by hand because the customer could not pull it themselves. Self-service or automated certificates do not count.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task_coi';

-- ---------- 2. relationship type ----------
ALTER TABLE public.sales_log DROP CONSTRAINT IF EXISTS sales_log_household_status_check;
ALTER TABLE public.sales_log ADD CONSTRAINT sales_log_household_status_check
  CHECK (household_status = ANY (ARRAY['new'::text, 'existing'::text, 'winback'::text]));

ALTER TABLE public.quote_log ADD COLUMN IF NOT EXISTS relationship_type text;
ALTER TABLE public.quote_log DROP CONSTRAINT IF EXISTS quote_log_relationship_type_check;
ALTER TABLE public.quote_log ADD CONSTRAINT quote_log_relationship_type_check
  CHECK (relationship_type IS NULL OR relationship_type = ANY (ARRAY['new'::text, 'existing'::text, 'winback'::text]));

-- ---------- 3. marketing source + GNC on quotes ----------
ALTER TABLE public.quote_log ADD COLUMN IF NOT EXISTS marketing_source text;
ALTER TABLE public.quote_log ADD COLUMN IF NOT EXISTS gnc_used boolean;
ALTER TABLE public.quote_log ADD COLUMN IF NOT EXISTS sourced_by_team_member_id uuid REFERENCES public.team(id);

COMMENT ON COLUMN public.quote_log.relationship_type IS 'new / existing / winback. Set from the entry page; is_existing_customer is derived from it.';
COMMENT ON COLUMN public.quote_log.marketing_source IS 'sales_marketing_sources.source_key. Tracking only; a quote pays nothing.';
COMMENT ON COLUMN public.quote_log.gnc_used IS 'Good Neighbor Connect used on this quote.';
COMMENT ON COLUMN public.quote_log.sourced_by_team_member_id IS 'Who sourced the lead when the marketing source is a referral. Tracking only.';

CREATE OR REPLACE FUNCTION public.rp_log_quote(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_label text; v_prods text[]; v_url text; v_id uuid; x text;
  v_rel text; v_existing boolean; v_src text; v_gnc boolean; v_sourced uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'quote_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log a quote within 7 days'; END IF;
  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  SELECT COALESCE(array_agg(DISTINCT lower(e)), ARRAY[]::text[]) INTO v_prods FROM jsonb_array_elements_text(COALESCE(p->'products_discussed','[]'::jsonb)) e;
  IF cardinality(v_prods) = 0 THEN RAISE EXCEPTION 'click every product you discussed. At least one.'; END IF;
  FOREACH x IN ARRAY v_prods LOOP
    IF x NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', x; END IF;
  END LOOP;
  v_url := NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),'');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  -- relationship type (new / existing / winback). Optional on a quote. The old
  -- is_existing_customer flag is filled from it; a caller that still sends only
  -- the flag keeps working.
  v_rel := NULLIF(lower(btrim(COALESCE(p->>'relationship_type',''))),'');
  IF v_rel IS NOT NULL AND v_rel NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'relationship type must be new, existing, or winback';
  END IF;
  v_existing := CASE WHEN v_rel IS NOT NULL THEN v_rel = 'existing'
                     ELSE COALESCE((p->>'is_existing_customer')::boolean, false) END;

  -- marketing source, Good Neighbor Connect, sourced-by: tracking only
  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')),'');
  IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources WHERE agency_id=a.agency_id AND source_key=v_src AND is_active) THEN
    RAISE EXCEPTION 'unknown marketing source';
  END IF;
  v_gnc := CASE WHEN NULLIF(p->>'gnc_used','') IS NULL THEN NULL ELSE (p->>'gnc_used')::boolean END;
  v_sourced := NULLIF(p->>'sourced_by_team_member_id','')::uuid;
  IF v_sourced IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team WHERE id=v_sourced AND agency_id=a.agency_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'sourced-by team member not found';
  END IF;

  INSERT INTO public.quote_log (agency_id, team_member_id, quote_date, week_end_date, customer_first_name, customer_last_initial, customer_label,
    is_existing_customer, relationship_type, marketing_source, gnc_used, sourced_by_team_member_id,
    ecrm_opportunity_url, products_discussed, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on), btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
    v_existing, v_rel, v_src, v_gnc, v_sourced,
    v_url, v_prods, NULLIF(btrim(COALESCE(p->>'note','')),''), a.actor_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'quote_id', v_id, 'customer', v_label, 'products_discussed', to_jsonb(v_prods),
                            'relationship_type', v_rel, 'marketing_source', v_src);
END $function$;

-- rp_log_sale: winback accepted. A winback household has nothing in force, so
-- its first line is the anchor just like a brand-new household (locked rule: a
-- new household's first line is not a multiline). Only the two status checks
-- change; everything else is byte-for-byte the shipped function.
CREATE OR REPLACE FUNCTION public.rp_log_sale(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_status text; v_url text; v_src text; v_gnc boolean; v_veh integer;
  v_sourced uuid; v_sale_id uuid; prod jsonb; v_lob text; v_prem numeric; v_cnt integer; v_new boolean;
  v_total numeric := 0; v_lines int := 0; v_has_auto boolean := false;
  v_anchor text; v_ml_pts numeric; v_ref_pts numeric; v_credit_id uuid;
  v_credits jsonb := '[]'::jsonb; v_rp numeric := 0; v_note text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'sale_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'sale date cannot be in the future'; END IF;
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
    RAISE EXCEPTION 'add at least one product with its premium';
  END IF;
  -- validate products first
  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(COALESCE(prod->>'line_of_business',''));
    IF v_lob NOT IN ('auto','fire','business','life','health','ips','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
    v_prem := NULLIF(prod->>'premium','')::numeric;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'premium required for %', v_lob; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_lob; END IF;
    IF v_lob = 'auto' THEN v_has_auto := true; END IF;
    v_total := v_total + v_prem;
  END LOOP;
  v_veh := NULLIF(p->>'vehicle_count','')::integer;
  IF v_has_auto AND (v_veh IS NULL OR v_veh < 1) THEN RAISE EXCEPTION 'how many cars?'; END IF;
  IF NOT v_has_auto THEN v_veh := NULL; END IF;

  INSERT INTO public.sales_log (agency_id, team_member_id, sourced_by_team_member_id, sale_date, week_end_date,
    customer_first_name, customer_last_initial, customer_label, household_status, ecrm_opportunity_url,
    marketing_source, gnc_used, vehicle_count, total_premium, note, created_by)
  VALUES (a.agency_id, a.team_member_id, v_sourced, v_on, public.rp_week_end(v_on),
    btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_status, v_url,
    v_src, v_gnc, v_veh, v_total, v_note, a.actor_id)
  RETURNING id INTO v_sale_id;

  SELECT points INTO v_ml_pts  FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='multiline_sold' AND is_active;
  SELECT points INTO v_ref_pts FROM public.retention_point_values WHERE agency_id=a.agency_id AND activity_key='referral_sold' AND is_active;

  -- anchor line for a household with nothing in force (new or winback) = highest premium among new lines (no multiline credit on it)
  IF v_status IN ('new','winback') THEN
    SELECT lower(x->>'line_of_business') INTO v_anchor
    FROM jsonb_array_elements(p->'products') x
    WHERE COALESCE((x->>'is_new_line')::boolean, true)
    ORDER BY NULLIF(x->>'premium','')::numeric DESC NULLS LAST, lower(x->>'line_of_business') LIMIT 1;
  END IF;

  FOR prod IN SELECT * FROM jsonb_array_elements(p->'products') LOOP
    v_lob := lower(prod->>'line_of_business');
    v_prem := NULLIF(prod->>'premium','')::numeric;
    v_cnt := GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1));
    v_new := COALESCE((prod->>'is_new_line')::boolean, true);
    v_credit_id := NULL;
    IF v_new AND v_ml_pts IS NOT NULL AND (v_status = 'existing' OR v_lob IS DISTINCT FROM v_anchor) THEN
      INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
        customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by)
      VALUES (a.agency_id, v_sourced, 'multiline_sold', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
        btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label, v_url,
        'From sale entry: ' || v_lob || ' added to household', v_ml_pts, 'sales_log', v_sale_id, a.actor_id)
      RETURNING id INTO v_credit_id;
      v_rp := v_rp + v_ml_pts; v_lines := v_lines + 1;
      v_credits := v_credits || jsonb_build_object('activity_key','multiline_sold','line',v_lob,'points',v_ml_pts);
    END IF;
    INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, premium, policy_count, is_new_line, multiline_credit_id)
    VALUES (v_sale_id, a.agency_id, v_lob, v_prem, v_cnt, v_new, v_credit_id);
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
                            'retention_points', v_rp, 'credits', v_credits, 'sourced_by', v_sourced);
END $function$;

-- ---------- 4. rp_log_entry: shared relationship / source / GNC, several cancelled lines ----------
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
  -- shared by quote and sale (Peter: they apply to more than one thing)
  v_rel    text  := NULLIF(lower(btrim(COALESCE(p->>'relationship_type', ''))), '');
  v_src    text  := NULLIF(btrim(COALESCE(p->>'marketing_source', '')), '');
  v_gnc    text  := NULLIF(p->>'gnc_used', '');
  v_srcby  text  := NULLIF(p->>'sourced_by_team_member_id', '');
  v_act    jsonb := p->'activity';
  v_quote  jsonb := p->'quote';
  v_sale   jsonb := p->'sale';
  v_cxl    jsonb := p->'cancellation';
  v_items  jsonb := '[]'::jsonb;
  v_shared jsonb;
  it       jsonb;
  v_cnt    integer;
  i        integer;
  v_lines  text[];
  v_line   text;
  r_act    jsonb; r_quote jsonb; r_sale jsonb; r_cxl jsonb := '[]'::jsonb; r_one jsonb;
BEGIN
  -- a section counts only when it has content
  IF v_act IS NULL OR jsonb_typeof(v_act) <> 'object'
     OR jsonb_typeof(v_act->'items') <> 'array' OR jsonb_array_length(v_act->'items') = 0 THEN
    v_act := NULL;
  END IF;
  IF v_quote IS NULL OR jsonb_typeof(v_quote) <> 'object'
     OR jsonb_typeof(v_quote->'products_discussed') <> 'array' OR jsonb_array_length(v_quote->'products_discussed') = 0 THEN
    v_quote := NULL;
  END IF;
  IF v_sale IS NULL OR jsonb_typeof(v_sale) <> 'object'
     OR jsonb_typeof(v_sale->'products') <> 'array' OR jsonb_array_length(v_sale->'products') = 0 THEN
    v_sale := NULL;
  END IF;
  -- cancellation: several lines (policy_lines) or the older single policy_line
  IF v_cxl IS NOT NULL AND jsonb_typeof(v_cxl) = 'object' THEN
    IF jsonb_typeof(v_cxl->'policy_lines') = 'array' THEN
      SELECT COALESCE(array_agg(DISTINCT lower(btrim(e))) FILTER (WHERE btrim(e) <> ''), ARRAY[]::text[])
        INTO v_lines FROM jsonb_array_elements_text(v_cxl->'policy_lines') e;
    ELSIF NULLIF(btrim(COALESCE(v_cxl->>'policy_line', '')), '') IS NOT NULL THEN
      v_lines := ARRAY[lower(btrim(v_cxl->>'policy_line'))];
    END IF;
  END IF;
  IF v_lines IS NULL OR cardinality(v_lines) = 0 THEN v_cxl := NULL; END IF;

  IF v_act IS NULL AND v_quote IS NULL AND v_sale IS NULL AND v_cxl IS NULL THEN
    RAISE EXCEPTION 'add at least one thing to log: an activity, a quote, a sale, or a cancellation';
  END IF;

  -- the one hard contradiction: sold and cancelled on the same line in one entry
  IF v_sale IS NOT NULL AND v_cxl IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sale->'products') x
               WHERE lower(btrim(COALESCE(x->>'line_of_business', ''))) = ANY (v_lines)) THEN
      RAISE EXCEPTION 'a sale and a cancellation on the same policy line cannot go in one entry. Log them separately.';
    END IF;
  END IF;

  v_shared := jsonb_build_object(
    'customer_first', v_first, 'customer_last_initial', v_init,
    'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm,
    'relationship_type', v_rel, 'household_status', v_rel,
    'marketing_source', v_src, 'gnc_used', v_gnc, 'sourced_by_team_member_id', v_srcby);

  -- 1. activity (counts expand to one row per task)
  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN
        RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.';
      END IF;
      FOR i IN 1..v_cnt LOOP
        v_items := v_items || (it - 'count');
      END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm);
  END IF;

  -- 2. quote
  IF v_quote IS NOT NULL THEN
    r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on));
  END IF;

  -- 3. sale (the ECRM link is required here; rp_log_sale says so if it is missing)
  IF v_sale IS NOT NULL THEN
    r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('sale_date', v_on));
  END IF;

  -- 4. cancellation, one row per cancelled line (last, so its trigger sees any save logged above)
  IF v_cxl IS NOT NULL THEN
    FOREACH v_line IN ARRAY v_lines LOOP
      r_one := public.rp_log_cancellation(jsonb_build_object(
        'customer_first', v_first, 'customer_last_initial', v_init, 'cancelled_on', v_on,
        'policy_line', v_line, 'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'customer', public.rp_customer_label(v_first, v_init),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancellation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END);
END $function$;

COMMENT ON FUNCTION public.rp_log_entry(jsonb) IS
  'One Log button: activity items (with counts), quote, sale, and one or more cancelled lines for one customer in one transaction. Relationship type, marketing source, GNC, and sourced-by sit at the top of the payload and are shared by the quote and the sale. Blocks a sale and a cancellation on the same line in one entry.';
