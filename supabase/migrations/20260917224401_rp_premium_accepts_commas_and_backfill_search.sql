-- Peter 2026-09-17:
--  * a premium typed with commas or a dollar sign is a number. rp_mark_issued
--    strips the formatting instead of failing, so every screen that issues a
--    policy accepts it, not just the backfill form.
--  * a search on the backfill list, so a record can be pulled up by name even
--    when it is missing nothing and has therefore dropped off the list.

CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_raw text; v_n integer := 0;
  v_today date := public.rp_today_central();
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_on := COALESCE(NULLIF(it->>'issued_date','')::date, v_today);
    -- "$1,527.10" is a premium. Drop the formatting, keep the number.
    v_raw := NULLIF(regexp_replace(COALESCE(it->>'issued_premium',''), '[^0-9.\-]', '', 'g'), '');
    IF v_raw IS NOT NULL AND v_raw !~ '^-?[0-9]*\.?[0-9]+$' THEN
      RAISE EXCEPTION 'the issued premium has to be a number';
    END IF;
    v_prem := v_raw::numeric;
    IF v_on > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;
    SELECT s.submitted_date INTO v_sub
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;
    IF v_on < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
    UPDATE public.sales_log_products SET issued_date = v_on, issued_premium = v_prem WHERE id = v_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_backfill_queue(p_limit integer DEFAULT 25, p_offset integer DEFAULT 0, p_search text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_total integer; v_rows jsonb; v_q text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  v_q := NULLIF(btrim(COALESCE(p_search,'')), '');

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
      AND (v_q IS NULL OR s.customer_label ILIKE '%' || v_q || '%')
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
      AND (v_q IS NULL OR q.customer_label ILIKE '%' || v_q || '%')
  ),
  open_rows AS (
    -- searching shows every record for that name, gaps or not. Otherwise only gaps.
    SELECT * FROM gaps
     WHERE v_q IS NOT NULL OR needs_phone OR needs_ecrm OR needs_marketing OR needs_referral OR needs_issued
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

  RETURN jsonb_build_object('ok', true, 'total_rows', COALESCE(v_total, 0),
                            'searching', (v_q IS NOT NULL), 'rows', COALESCE(v_rows, '[]'::jsonb));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_backfill_queue(integer, integer, text) TO authenticated;
