-- Removes a stray CREATE TEMP TABLE / DROP TABLE placeholder that was left in
-- rp_backfill_queue by mistake. A temp table inside a function called over the
-- REST layer returns HTTP 400 even when the function itself runs clean, and a
-- STABLE function cannot do it at all.

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
           (q.phone_last4 IS NULL),
           (COALESCE(btrim(q.ecrm_opportunity_url),'') = ''),
           (COALESCE(btrim(q.marketing_source),'') = ''),
           'quote'
    FROM public.quote_log q
    WHERE q.agency_id = a.agency_id AND q.status = 'active'
      AND (q.phone_last4 IS NULL OR COALESCE(btrim(q.ecrm_opportunity_url),'') = '' OR COALESCE(btrim(q.marketing_source),'') = '')
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
