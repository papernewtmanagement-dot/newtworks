-- Backfill tab sorting (Peter 2026-09-19). The list is paged on the server, so
-- the sort has to happen there too, or "sort by name" only sorts the 25 rows
-- you happen to be looking at. Callers checked before the drop: no database
-- function calls this, and the only caller in the app is BackfillTab.jsx.
DROP FUNCTION IF EXISTS public.rp_backfill_queue(integer, integer, text);

CREATE FUNCTION public.rp_backfill_queue(
  p_limit integer DEFAULT 25,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL::text,
  p_sort text DEFAULT 'date',
  p_dir text DEFAULT 'desc'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; v_total integer; v_rows jsonb; v_q text;
  v_sort text := lower(btrim(COALESCE(p_sort, 'date')));
  v_desc boolean := lower(btrim(COALESCE(p_dir, 'desc'))) <> 'asc';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  v_q := NULLIF(btrim(COALESCE(p_search,'')), '');
  IF v_sort NOT IN ('date','customer','kind','missing') THEN v_sort := 'date'; END IF;

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
    SELECT g.*,
           (g.needs_phone::int + g.needs_ecrm::int + g.needs_marketing::int
            + g.needs_referral::int + g.needs_issued::int) AS missing_count
    FROM gaps g
     WHERE v_q IS NOT NULL OR g.needs_phone OR g.needs_ecrm OR g.needs_marketing OR g.needs_referral OR g.needs_issued
  ),
  page AS (
    SELECT z.*, row_number() OVER () AS rn
    FROM (
      SELECT * FROM open_rows
      ORDER BY
        CASE WHEN v_sort = 'date'     AND v_desc     THEN on_date END DESC NULLS LAST,
        CASE WHEN v_sort = 'date'     AND NOT v_desc THEN on_date END ASC  NULLS LAST,
        CASE WHEN v_sort = 'customer' AND v_desc     THEN lower(customer_label) END DESC NULLS LAST,
        CASE WHEN v_sort = 'customer' AND NOT v_desc THEN lower(customer_label) END ASC  NULLS LAST,
        CASE WHEN v_sort = 'kind'     AND v_desc     THEN kind END DESC NULLS LAST,
        CASE WHEN v_sort = 'kind'     AND NOT v_desc THEN kind END ASC  NULLS LAST,
        CASE WHEN v_sort = 'missing'  AND v_desc     THEN missing_count END DESC NULLS LAST,
        CASE WHEN v_sort = 'missing'  AND NOT v_desc THEN missing_count END ASC  NULLS LAST,
        on_date DESC, customer_label, kind
      LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
    ) z
  )
  SELECT (SELECT count(*) FROM open_rows),
         COALESCE(jsonb_agg(jsonb_build_object(
           'kind', kind, 'id', id, 'customer_label', customer_label, 'on_date', on_date, 'detail', detail,
           'phone_last4', phone_last4, 'ecrm', ecrm, 'marketing_source', marketing_source,
           'referred_by_customer', referred_by_customer, 'sourced_by_team_member_id', sourced_by_team_member_id,
           'needs_phone', needs_phone, 'needs_ecrm', needs_ecrm,
           'needs_marketing', needs_marketing, 'needs_referral', needs_referral,
           'needs_issued', needs_issued, 'missing_count', missing_count, 'policies', policies
         ) ORDER BY rn), '[]'::jsonb)
    INTO v_total, v_rows
  FROM page;

  RETURN jsonb_build_object('ok', true, 'total_rows', COALESCE(v_total, 0),
                            'searching', (v_q IS NOT NULL),
                            'sort', v_sort, 'dir', CASE WHEN v_desc THEN 'desc' ELSE 'asc' END,
                            'rows', COALESCE(v_rows, '[]'::jsonb));
END $function$;

REVOKE ALL ON FUNCTION public.rp_backfill_queue(integer, integer, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rp_backfill_queue(integer, integer, text, text, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.rp_backfill_queue(integer, integer, text, text, text) IS
  'Dashboard > Backfill. Owner and managers only. p_sort: date | customer | kind | missing. p_dir: asc | desc. Sorted on the server so the order holds across pages.';
