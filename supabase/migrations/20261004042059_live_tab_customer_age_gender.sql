-- Live tab (Peter 2026-10-04): the customer's age and gender, asked on each Live call,
-- go onto every record the entry writes, the same way the phone last four does:
-- rp_log_entry checks them and sets them for the transaction, and a BEFORE INSERT
-- trigger copies them onto the row. Both are optional; the Log tab does not send them.

ALTER TABLE public.quote_log
  ADD COLUMN IF NOT EXISTS customer_age smallint CHECK (customer_age BETWEEN 15 AND 110),
  ADD COLUMN IF NOT EXISTS customer_gender text CHECK (customer_gender IN ('male', 'female'));
ALTER TABLE public.sales_log
  ADD COLUMN IF NOT EXISTS customer_age smallint CHECK (customer_age BETWEEN 15 AND 110),
  ADD COLUMN IF NOT EXISTS customer_gender text CHECK (customer_gender IN ('male', 'female'));
ALTER TABLE public.retention_activity_log
  ADD COLUMN IF NOT EXISTS customer_age smallint CHECK (customer_age BETWEEN 15 AND 110),
  ADD COLUMN IF NOT EXISTS customer_gender text CHECK (customer_gender IN ('male', 'female'));
ALTER TABLE public.fit_scorecards
  ADD COLUMN IF NOT EXISTS customer_age smallint CHECK (customer_age BETWEEN 15 AND 110),
  ADD COLUMN IF NOT EXISTS customer_gender text CHECK (customer_gender IN ('male', 'female'));
ALTER TABLE public.cancelation_log
  ADD COLUMN IF NOT EXISTS customer_age smallint CHECK (customer_age BETWEEN 15 AND 110),
  ADD COLUMN IF NOT EXISTS customer_gender text CHECK (customer_gender IN ('male', 'female'));

CREATE OR REPLACE FUNCTION public.rp_fill_age_gender()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_age text := NULLIF(current_setting('rp.customer_age', true), '');
  v_gen text := NULLIF(current_setting('rp.customer_gender', true), '');
BEGIN
  IF NEW.customer_age IS NULL AND v_age IS NOT NULL THEN NEW.customer_age := v_age::smallint; END IF;
  IF NEW.customer_gender IS NULL AND v_gen IS NOT NULL THEN NEW.customer_gender := v_gen; END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE TRIGGER trg_fill_age_gender BEFORE INSERT ON public.quote_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_age_gender();
CREATE OR REPLACE TRIGGER trg_fill_age_gender BEFORE INSERT ON public.sales_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_age_gender();
CREATE OR REPLACE TRIGGER trg_fill_age_gender BEFORE INSERT ON public.retention_activity_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_age_gender();
CREATE OR REPLACE TRIGGER trg_fill_age_gender BEFORE INSERT ON public.fit_scorecards FOR EACH ROW EXECUTE FUNCTION public.rp_fill_age_gender();
CREATE OR REPLACE TRIGGER trg_fill_age_gender BEFORE INSERT ON public.cancelation_log FOR EACH ROW EXECUTE FUNCTION public.rp_fill_age_gender();

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
  v_age    text  := NULLIF(btrim(COALESCE(p->>'customer_age', '')), '');
  v_gender text  := NULLIF(lower(btrim(COALESCE(p->>'customer_gender', ''))), '');
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
  PERFORM public.require_login('staff');
  -- customer phone, last four digits: required on every record, part of the household key (Peter 2026-09-11)
  IF regexp_replace(COALESCE(p_payload->>'phone_last4', ''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  PERFORM set_config('rp.phone_last4', regexp_replace(p_payload->>'phone_last4', '\D', '', 'g'), true);
  -- customer age and gender (Live tab, Peter 2026-10-04): optional; checked when given, then written onto
  -- every record this entry makes, the way the phone is (trigger rp_fill_age_gender)
  IF v_age IS NOT NULL AND (CASE WHEN v_age ~ '^\d{1,3}$' THEN v_age::integer NOT BETWEEN 15 AND 110 ELSE true END) THEN
    RAISE EXCEPTION 'customer age: a whole number from 15 to 110';
  END IF;
  IF v_gender IS NOT NULL AND v_gender NOT IN ('male', 'female') THEN
    RAISE EXCEPTION 'customer gender: male or female';
  END IF;
  PERFORM set_config('rp.customer_age', COALESCE(v_age, ''), true);
  PERFORM set_config('rp.customer_gender', COALESCE(v_gender, ''), true);
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
        'replacement', COALESCE((it->>'replacement')::boolean, false),
        'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;
  IF v_card IS NOT NULL THEN r_card := public.rp_log_scorecard(v_shared || v_card || jsonb_build_object('scorecard_date', v_on)); END IF;
  RETURN jsonb_build_object('ok', true, 'customer', public.rp_customer_label(v_first, v_init, v_kind),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancelation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END, 'scorecard', r_card);
END $function$;

