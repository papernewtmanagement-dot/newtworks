-- Peter 2026-09-17, second pass on the backfill form:
--  * rows, not one household at a time, saved as a batch
--  * the ECRM link is typed straight in, no extra click, because he is already
--    in ECRM getting the phone number
--  * referral detail (which customer referred it, who on the team sourced it)
--    is a gap too, so it belongs in the list
--  * cancelations never ask for anything. Every one of them is matched to a
--    sale product, so the phone comes from the sale it cancels.
-- The one-time UPDATE at the end pushes the phone from matched sales onto the
-- cancelations that already have one to copy.

CREATE OR REPLACE FUNCTION public.rp_backfill_queue(p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_total integer; v_rows jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;

  WITH gaps AS (
    SELECT 'sale'::text AS kind, s.id, s.customer_label, s.submitted_date AS on_date,
           s.phone_last4, s.ecrm_opportunity_url AS ecrm, s.marketing_source,
           s.referred_by_customer, s.sourced_by_team_member_id,
           (s.phone_last4 IS NULL) AS needs_phone,
           (COALESCE(btrim(s.ecrm_opportunity_url),'') = '') AS needs_ecrm,
           (COALESCE(btrim(s.marketing_source),'') = '') AS needs_marketing,
           (s.marketing_source = 'referral' AND s.referred_by_customer IS NULL AND s.sourced_by_team_member_id IS NULL) AS needs_referral,
           COALESCE((SELECT string_agg(p.product_type || ' $' || to_char(COALESCE(p.premium,0),'FM999999990'), ', ' ORDER BY p.line_of_business, p.id)
                     FROM public.sales_log_products p WHERE p.sales_log_id = s.id), 'sale') AS detail
    FROM public.sales_log s
    WHERE s.agency_id = a.agency_id AND s.status = 'active'
    UNION ALL
    SELECT 'quote', q.id, q.customer_label, q.quote_date,
           q.phone_last4, NULL, q.marketing_source,
           q.referred_by_customer, q.sourced_by_team_member_id,
           (q.phone_last4 IS NULL), false,
           (COALESCE(btrim(q.marketing_source),'') = ''),
           (q.marketing_source = 'referral' AND q.referred_by_customer IS NULL AND q.sourced_by_team_member_id IS NULL),
           'quote'
    FROM public.quote_log q
    WHERE q.agency_id = a.agency_id AND q.status = 'active'
  ),
  open_rows AS (
    SELECT * FROM gaps WHERE needs_phone OR needs_ecrm OR needs_marketing OR needs_referral
  ),
  page AS (
    SELECT * FROM open_rows
    ORDER BY on_date DESC, customer_label, kind
    LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
  )
  SELECT (SELECT count(*) FROM open_rows),
         COALESCE(jsonb_agg(jsonb_build_object(
           'kind', kind, 'id', id, 'customer_label', customer_label, 'on_date', on_date, 'detail', detail,
           'phone_last4', phone_last4, 'ecrm', ecrm, 'marketing_source', marketing_source,
           'referred_by_customer', referred_by_customer, 'sourced_by_team_member_id', sourced_by_team_member_id,
           'needs_phone', needs_phone, 'needs_ecrm', needs_ecrm,
           'needs_marketing', needs_marketing, 'needs_referral', needs_referral
         ) ORDER BY on_date DESC, customer_label, kind), '[]'::jsonb)
    INTO v_total, v_rows
  FROM page;

  RETURN jsonb_build_object('ok', true, 'total_rows', COALESCE(v_total, 0), 'rows', COALESCE(v_rows, '[]'::jsonb));
END $function$;

DROP FUNCTION IF EXISTS public.rp_backfill_save(jsonb);

CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; v_id uuid; v_kind text; v_label text;
  v_phone text; v_ecrm text; v_src text; v_refcust text; v_refby uuid;
  v_saved integer := 0; v_spread integer := 0; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'nothing to save'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'more than 200 rows in one save. Do it in two passes.'; END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_kind := lower(COALESCE(rec->>'kind',''));
    v_id   := NULLIF(rec->>'id','')::uuid;
    IF v_id IS NULL OR v_kind NOT IN ('sale','quote') THEN CONTINUE; END IF;

    v_phone := NULLIF(regexp_replace(COALESCE(rec->>'phone_last4',''), '\D', '', 'g'), '');
    IF v_phone IS NOT NULL AND v_phone !~ '^\d{4}$' THEN
      RAISE EXCEPTION 'the last four digits of the phone, four numbers';
    END IF;

    v_ecrm := NULLIF(btrim(COALESCE(rec->>'ecrm','')), '');
    IF v_ecrm IS NOT NULL AND v_ecrm !~* '^https?://' THEN
      RAISE EXCEPTION 'an ECRM link has to start with http';
    END IF;

    v_src := NULLIF(btrim(COALESCE(rec->>'marketing_source','')), '');
    IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
        WHERE agency_id = a.agency_id AND source_key = v_src AND is_active) THEN
      RAISE EXCEPTION 'pick the marketing source';
    END IF;

    v_refcust := NULLIF(btrim(COALESCE(rec->>'referred_by_customer','')), '');
    v_refby   := NULLIF(rec->>'sourced_by_team_member_id','')::uuid;

    IF v_phone IS NULL AND v_ecrm IS NULL AND v_src IS NULL AND v_refcust IS NULL AND v_refby IS NULL THEN
      CONTINUE;
    END IF;

    IF v_kind = 'sale' THEN
      UPDATE public.sales_log SET
        phone_last4 = COALESCE(v_phone, phone_last4),
        ecrm_opportunity_url = COALESCE(v_ecrm, ecrm_opportunity_url),
        marketing_source = COALESCE(v_src, marketing_source),
        referred_by_customer = COALESCE(v_refcust, referred_by_customer),
        sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
        updated_at = now()
      WHERE id = v_id AND agency_id = a.agency_id AND status = 'active'
      RETURNING customer_label INTO v_label;
    ELSE
      UPDATE public.quote_log SET
        phone_last4 = COALESCE(v_phone, phone_last4),
        marketing_source = COALESCE(v_src, marketing_source),
        referred_by_customer = COALESCE(v_refcust, referred_by_customer),
        sourced_by_team_member_id = COALESCE(v_refby, sourced_by_team_member_id),
        updated_at = now()
      WHERE id = v_id AND agency_id = a.agency_id AND status = 'active'
      RETURNING customer_label INTO v_label;
    END IF;
    IF v_label IS NULL THEN CONTINUE; END IF;
    v_saved := v_saved + 1;

    -- The phone is the household key, so it lands on everything else under the
    -- same name that has none.
    IF v_phone IS NOT NULL THEN
      UPDATE public.sales_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.quote_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.cancelation_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.retention_activity_log SET phone_last4 = v_phone, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;
    END IF;
  END LOOP;

  -- A cancelation takes its phone from the sale product it cancels, always.
  UPDATE public.cancelation_log c SET phone_last4 = s.phone_last4, updated_at = now()
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE c.matched_sale_product_id = p.id
     AND c.agency_id = a.agency_id AND c.status = 'active'
     AND c.phone_last4 IS NULL AND s.phone_last4 IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_saved, 'also_filled', v_spread);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_backfill_save(jsonb) TO authenticated;

-- One-time: cancelations that already have a sale with a phone on it.
UPDATE public.cancelation_log c SET phone_last4 = s.phone_last4, updated_at = now()
  FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
 WHERE c.matched_sale_product_id = p.id
   AND c.status = 'active' AND c.phone_last4 IS NULL AND s.phone_last4 IS NOT NULL;
