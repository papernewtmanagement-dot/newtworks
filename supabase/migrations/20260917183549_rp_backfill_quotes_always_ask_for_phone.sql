-- Peter 2026-09-17: a quote needs its own phone last four, because that is what
-- proves the same household was not quoted twice in a week. So every quote
-- missing one is back in the backfill list. It still does not have to be typed
-- twice: the phone entered on the sale fills every record under the same name,
-- quotes included, both on screen and on save.

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
                        'premium', p.premium, 'issued_date', p.issued_date)
                        ORDER BY p.line_of_business, p.id)
                     FROM public.sales_log_products p
                    WHERE p.sales_log_id = s.id AND p.issued_date IS NOT NULL AND p.issued_premium IS NULL), '[]'::jsonb) AS policies
    FROM public.sales_log s
    WHERE s.agency_id = a.agency_id AND s.status = 'active'
    UNION ALL
    SELECT 'quote', q.id, q.customer_label, q.quote_date,
           q.phone_last4, NULL, q.marketing_source,
           q.referred_by_customer, q.sourced_by_team_member_id,
           (q.phone_last4 IS NULL),
           false,
           (COALESCE(btrim(q.marketing_source),'') = ''),
           (q.marketing_source = 'referral' AND q.referred_by_customer IS NULL AND q.sourced_by_team_member_id IS NULL),
           false,
           'quote',
           '[]'::jsonb
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
