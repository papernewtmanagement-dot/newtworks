-- The ECRM link is only required when a sale is recorded (Peter 2026-09-04), so
-- a quote without one is not a gap. Quotes now only appear in the backfill queue
-- when the phone last four or the marketing source is missing, and the ECRM
-- write is sales only.

CREATE OR REPLACE FUNCTION public.rp_backfill_queue(p_limit integer DEFAULT 40, p_offset integer DEFAULT 0)
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
           (s.phone_last4 IS NULL) AS needs_phone,
           (COALESCE(btrim(s.ecrm_opportunity_url),'') = '') AS needs_ecrm,
           (COALESCE(btrim(s.marketing_source),'') = '') AS needs_marketing,
           COALESCE((SELECT string_agg(p.product_type || ' $' || to_char(COALESCE(p.premium,0),'FM999999990.00'), ', ' ORDER BY p.line_of_business, p.id)
                     FROM public.sales_log_products p WHERE p.sales_log_id = s.id), 'sale') AS detail
    FROM public.sales_log s
    WHERE s.agency_id = a.agency_id AND s.status = 'active'
      AND (s.phone_last4 IS NULL OR COALESCE(btrim(s.ecrm_opportunity_url),'') = '' OR COALESCE(btrim(s.marketing_source),'') = '')
    UNION ALL
    SELECT 'quote', q.id, q.customer_label, q.quote_date,
           (q.phone_last4 IS NULL), false,
           (COALESCE(btrim(q.marketing_source),'') = ''),
           'quote'
    FROM public.quote_log q
    WHERE q.agency_id = a.agency_id AND q.status = 'active'
      AND (q.phone_last4 IS NULL OR COALESCE(btrim(q.marketing_source),'') = '')
    UNION ALL
    SELECT 'cancelation', c.id, c.customer_label, c.canceled_on,
           (c.phone_last4 IS NULL), false, false,
           'canceled ' || COALESCE(c.product_type, c.policy_line, '')
    FROM public.cancelation_log c
    WHERE c.agency_id = a.agency_id AND c.status = 'active' AND c.phone_last4 IS NULL
  ),
  hh AS (
    SELECT customer_label, max(on_date) AS newest, count(*) AS records
    FROM gaps GROUP BY customer_label
  ),
  page AS (
    SELECT * FROM hh ORDER BY newest DESC, customer_label LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
  )
  SELECT (SELECT count(*) FROM hh),
         COALESCE(jsonb_agg(jsonb_build_object(
           'customer_label', page.customer_label,
           'records', (SELECT jsonb_agg(jsonb_build_object(
                          'kind', g.kind, 'id', g.id, 'on_date', g.on_date, 'detail', g.detail,
                          'needs_phone', g.needs_phone, 'needs_ecrm', g.needs_ecrm, 'needs_marketing', g.needs_marketing)
                          ORDER BY g.on_date DESC)
                       FROM gaps g WHERE g.customer_label = page.customer_label)
         ) ORDER BY page.newest DESC, page.customer_label), '[]'::jsonb)
    INTO v_total, v_rows
  FROM page;

  RETURN jsonb_build_object('ok', true, 'total_households', COALESCE(v_total, 0), 'households', COALESCE(v_rows, '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_label text; v_phone text; v_src text; rec jsonb; v_url text;
  v_phone_rows integer := 0; v_src_rows integer := 0; v_ecrm_rows integer := 0; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;

  v_label := NULLIF(btrim(COALESCE(p->>'customer_label','')), '');
  IF v_label IS NULL THEN RAISE EXCEPTION 'which customer is this?'; END IF;

  v_phone := NULLIF(regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g'), '');
  IF v_phone IS NOT NULL AND v_phone !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'the last four digits of the phone, four numbers';
  END IF;

  v_src := NULLIF(btrim(COALESCE(p->>'marketing_source','')), '');
  IF v_src IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id = a.agency_id AND source_key = v_src AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;

  IF v_phone IS NOT NULL THEN
    UPDATE public.sales_log SET phone_last4 = v_phone, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT; v_phone_rows := v_phone_rows + n;

    UPDATE public.quote_log SET phone_last4 = v_phone, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT; v_phone_rows := v_phone_rows + n;

    UPDATE public.cancelation_log SET phone_last4 = v_phone, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT; v_phone_rows := v_phone_rows + n;

    UPDATE public.retention_activity_log SET phone_last4 = v_phone, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label AND phone_last4 IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT; v_phone_rows := v_phone_rows + n;
  END IF;

  IF v_src IS NOT NULL THEN
    UPDATE public.sales_log SET marketing_source = v_src, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
       AND COALESCE(btrim(marketing_source),'') = '';
    GET DIAGNOSTICS n = ROW_COUNT; v_src_rows := v_src_rows + n;

    UPDATE public.quote_log SET marketing_source = v_src, updated_at = now()
     WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
       AND COALESCE(btrim(marketing_source),'') = '';
    GET DIAGNOSTICS n = ROW_COUNT; v_src_rows := v_src_rows + n;
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'ecrm') = 'array' THEN p->'ecrm' ELSE '[]'::jsonb END) LOOP
    v_url := NULLIF(btrim(COALESCE(rec->>'url','')), '');
    CONTINUE WHEN v_url IS NULL;
    IF v_url !~* '^https?://' THEN RAISE EXCEPTION 'an ECRM link has to start with http'; END IF;
    UPDATE public.sales_log SET ecrm_opportunity_url = v_url, updated_at = now()
     WHERE id = (rec->>'id')::uuid AND agency_id = a.agency_id AND status = 'active';
    GET DIAGNOSTICS n = ROW_COUNT; v_ecrm_rows := v_ecrm_rows + n;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label,
                            'phone_rows', v_phone_rows, 'marketing_rows', v_src_rows, 'ecrm_rows', v_ecrm_rows);
END $function$;
