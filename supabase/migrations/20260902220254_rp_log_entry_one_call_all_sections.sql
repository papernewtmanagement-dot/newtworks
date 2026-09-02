-- rp_log_entry: one call logs everything that happened with one customer in one
-- contact. Activity items, a quote, a sale, and a cancellation all ride in one
-- payload and land in ONE transaction. Any failure rolls the whole entry back,
-- so a half-saved entry (activity written, sale rejected) cannot happen and the
-- team never re-submits and double-logs.
--
-- Wraps the existing writers unchanged:
--   rp_log_activity / rp_log_quote / rp_log_sale / rp_log_cancellation
-- Adds two things on top of them:
--   * activity items may carry "count" (service tasks are counters). The count
--     is expanded into one retention_activity_log row per task, so every task
--     stays its own checkable, voidable row.
--   * the one hard contradiction Peter named: a sale and a cancellation on the
--     same policy line cannot go in one entry.
--
-- Payload shape (all sections optional; at least one must have content):
-- {
--   "customer_first": "Anna", "customer_last_initial": "S",
--   "occurred_on": "2026-09-02", "ecrm_url": "https://...", "note": "...",
--   "team_member_id": null,
--   "activity":     { "items": [ {"activity_key":"service_task","count":3},
--                                {"activity_key":"cancellation_saved","save_line":"auto","save_reason":"..."} ] },
--   "quote":        { "products_discussed": ["auto","fire"], "is_existing_customer": false },
--   "sale":         { "household_status":"new", "marketing_source":"referral", "gnc_used":true,
--                     "vehicle_count":2, "sourced_by_team_member_id":null,
--                     "products":[{"line_of_business":"auto","premium":900,"policy_count":1,"is_new_line":true}] },
--   "cancellation": { "policy_line":"life", "reason":"..." }
-- }

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
  v_act    jsonb := p->'activity';
  v_quote  jsonb := p->'quote';
  v_sale   jsonb := p->'sale';
  v_cxl    jsonb := p->'cancellation';
  v_items  jsonb := '[]'::jsonb;
  it       jsonb;
  v_cnt    integer;
  i        integer;
  v_cxl_line text;
  r_act    jsonb; r_quote jsonb; r_sale jsonb; r_cxl jsonb;
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
  IF v_cxl IS NULL OR jsonb_typeof(v_cxl) <> 'object'
     OR NULLIF(btrim(COALESCE(v_cxl->>'policy_line', '')), '') IS NULL THEN
    v_cxl := NULL;
  END IF;

  IF v_act IS NULL AND v_quote IS NULL AND v_sale IS NULL AND v_cxl IS NULL THEN
    RAISE EXCEPTION 'add at least one thing to log: an activity, a quote, a sale, or a cancellation';
  END IF;

  -- the one hard contradiction: sold and cancelled on the same line in one entry
  IF v_sale IS NOT NULL AND v_cxl IS NOT NULL THEN
    v_cxl_line := lower(btrim(v_cxl->>'policy_line'));
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sale->'products') x
               WHERE lower(btrim(COALESCE(x->>'line_of_business', ''))) = v_cxl_line) THEN
      RAISE EXCEPTION 'a sale and a cancellation on the same policy line cannot go in one entry. Log them separately.';
    END IF;
  END IF;

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
    r_quote := public.rp_log_quote(v_quote || jsonb_build_object(
      'customer_first', v_first, 'customer_last_initial', v_init, 'quote_date', v_on,
      'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm));
  END IF;

  -- 3. sale (the ECRM link is required here; rp_log_sale says so if it is missing)
  IF v_sale IS NOT NULL THEN
    r_sale := public.rp_log_sale(v_sale || jsonb_build_object(
      'customer_first', v_first, 'customer_last_initial', v_init, 'sale_date', v_on,
      'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm));
  END IF;

  -- 4. cancellation (last, so its trigger sees any save logged above)
  IF v_cxl IS NOT NULL THEN
    r_cxl := public.rp_log_cancellation(v_cxl || jsonb_build_object(
      'customer_first', v_first, 'customer_last_initial', v_init, 'cancelled_on', v_on,
      'note', v_note, 'team_member_id', v_tm));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'customer', public.rp_customer_label(v_first, v_init),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale, 'cancellation', r_cxl);
END $function$;

COMMENT ON FUNCTION public.rp_log_entry(jsonb) IS
  'One Log button: activity items (with counts), quote, sale, cancellation for one customer in one transaction. Wraps rp_log_activity / rp_log_quote / rp_log_sale / rp_log_cancellation. Blocks a sale and a cancellation on the same line in one entry.';

REVOKE ALL ON FUNCTION public.rp_log_entry(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_log_entry(jsonb) TO authenticated;
