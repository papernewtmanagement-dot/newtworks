-- Peter 2026-09-17, fourth pass on the backfill form:
--  * every policy on a sale shows in the form, not only the ones missing an
--    issued premium, so there is always somewhere to put one
--  * issuing goes through rp_mark_issued, the same function the To Be Issued
--    tab uses, instead of writing the columns here. One job, one function.
-- What decides whether a row is in the list is unchanged: a policy that has an
-- issue date but no issued premium. A policy that has not issued yet is not a
-- gap, it just shows on the row when the row is there for another reason.

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
           EXISTS (SELECT 1 FROM public.sales_log_products p
                    WHERE p.sales_log_id = s.id AND p.issued_date IS NOT NULL AND p.issued_premium IS NULL) AS needs_issued,
           COALESCE((SELECT string_agg(p.product_type || ' $' || to_char(COALESCE(p.premium,0),'FM999999990'), ', ' ORDER BY p.line_of_business, p.id)
                     FROM public.sales_log_products p WHERE p.sales_log_id = s.id), 'sale') AS detail,
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
                        'id', p.id, 'product_type', p.product_type, 'line_of_business', p.line_of_business,
                        'premium', p.premium, 'issued_date', p.issued_date, 'issued_premium', p.issued_premium,
                        'needs_premium', (p.issued_date IS NOT NULL AND p.issued_premium IS NULL))
                        ORDER BY p.line_of_business, p.id)
                     FROM public.sales_log_products p WHERE p.sales_log_id = s.id), '[]'::jsonb) AS policies
    FROM public.sales_log s
    WHERE s.agency_id = a.agency_id AND s.status = 'active'
    UNION ALL
    SELECT 'quote', q.id, q.customer_label, q.quote_date,
           q.phone_last4, NULL, q.marketing_source,
           q.referred_by_customer, q.sourced_by_team_member_id,
           (q.phone_last4 IS NULL), false,
           (COALESCE(btrim(q.marketing_source),'') = ''),
           (q.marketing_source = 'referral' AND q.referred_by_customer IS NULL AND q.sourced_by_team_member_id IS NULL),
           false, 'quote', '[]'::jsonb
    FROM public.quote_log q
    WHERE q.agency_id = a.agency_id AND q.status = 'active'
  ),
  open_rows AS (
    SELECT * FROM gaps WHERE needs_phone OR needs_ecrm OR needs_marketing OR needs_referral OR needs_issued
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
           'needs_marketing', needs_marketing, 'needs_referral', needs_referral,
           'needs_issued', needs_issued, 'policies', policies
         ) ORDER BY on_date DESC, customer_label, kind), '[]'::jsonb)
    INTO v_total, v_rows
  FROM page;

  RETURN jsonb_build_object('ok', true, 'total_rows', COALESCE(v_total, 0), 'rows', COALESCE(v_rows, '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; pol jsonb; v_id uuid; v_kind text; v_label text;
  v_phone text; v_ecrm text; v_src text; v_refcust text; v_refby uuid;
  v_items jsonb; v_touched boolean;
  v_saved integer := 0; v_spread integer := 0; v_issued integer := 0; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'nothing to save'; END IF;
  IF jsonb_array_length(p_rows) > 200 THEN RAISE EXCEPTION 'more than 200 rows in one save. Do it in two passes.'; END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_kind := lower(COALESCE(rec->>'kind',''));
    v_id   := NULLIF(rec->>'id','')::uuid;
    IF v_id IS NULL OR v_kind NOT IN ('sale','quote') THEN CONTINUE; END IF;
    v_touched := false;
    v_label := NULL;

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

    IF v_phone IS NOT NULL OR v_ecrm IS NOT NULL OR v_src IS NOT NULL OR v_refcust IS NOT NULL OR v_refby IS NOT NULL THEN
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
      IF v_label IS NOT NULL THEN v_touched := true; END IF;
    END IF;

    -- Issuing a policy is rp_mark_issued's job, here as everywhere else.
    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      SELECT jsonb_agg(jsonb_build_object(
               'sale_product_id', x->>'id',
               'issued_date', COALESCE(NULLIF(x->>'issued_date',''), (SELECT p.issued_date::text FROM public.sales_log_products p
                                                                       WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id)),
               'issued_premium', x->>'issued_premium'))
        INTO v_items
        FROM jsonb_array_elements(rec->'policies') x
       WHERE NULLIF(btrim(COALESCE(x->>'issued_premium','')), '') IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.sales_log_products p
                      WHERE p.id = (x->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id);
      IF v_items IS NOT NULL AND jsonb_array_length(v_items) > 0 THEN
        PERFORM public.rp_mark_issued(v_items);
        v_issued := v_issued + jsonb_array_length(v_items);
        v_touched := true;
      END IF;
    END IF;

    IF v_touched THEN v_saved := v_saved + 1; END IF;

    IF v_phone IS NOT NULL AND v_label IS NOT NULL THEN
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

  UPDATE public.cancelation_log c SET phone_last4 = s.phone_last4, updated_at = now()
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE c.matched_sale_product_id = p.id
     AND c.agency_id = a.agency_id AND c.status = 'active'
     AND c.phone_last4 IS NULL AND s.phone_last4 IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

  RETURN jsonb_build_object('ok', true, 'rows_saved', v_saved, 'policies_issued', v_issued, 'also_filled', v_spread);
END $function$;
