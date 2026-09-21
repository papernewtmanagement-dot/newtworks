-- Peter 2026-09-20: the backfill has to show who the record belongs to, and
-- sort by it. A household can hold records from more than one person, so the
-- line carries every name in it and sorts on the first one alphabetically.

CREATE OR REPLACE FUNCTION public.rp_backfill_queue(p_limit integer DEFAULT 25, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_sort text DEFAULT 'date'::text, p_dir text DEFAULT 'desc'::text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; v_households integer; v_rows integer; v_out jsonb; v_q text;
  v_sort text := lower(btrim(COALESCE(p_sort, 'date')));
  v_desc boolean := lower(btrim(COALESCE(p_dir, 'desc'))) <> 'asc';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  v_q := NULLIF(btrim(COALESCE(p_search,'')), '');
  -- 'kind' no longer sorts anything: a household holds both kinds at once.
  IF v_sort NOT IN ('date','customer','missing','owner') THEN v_sort := 'date'; END IF;

  WITH gaps AS (
    SELECT 'sale'::text AS kind, s.id, s.customer_label, s.submitted_date AS on_date,
           s.team_member_id, t.first_name AS owner,
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
    LEFT JOIN public.team_directory t ON t.id = s.team_member_id
    WHERE s.agency_id = a.agency_id AND s.status = 'active'
      AND (v_q IS NULL OR s.customer_label ILIKE '%' || v_q || '%')
    UNION ALL
    SELECT 'quote', q.id, q.customer_label, q.quote_date,
           q.team_member_id, t.first_name,
           q.phone_last4, NULL, q.marketing_source,
           q.referred_by_customer, q.sourced_by_team_member_id,
           (q.phone_last4 IS NULL), false,
           (COALESCE(btrim(q.marketing_source),'') = ''),
           (q.marketing_source = 'referral' AND q.referred_by_customer IS NULL AND q.sourced_by_team_member_id IS NULL),
           false, 'quote', '[]'::jsonb
    FROM public.quote_log q
    LEFT JOIN public.team_directory t ON t.id = q.team_member_id
    WHERE q.agency_id = a.agency_id AND q.status = 'active'
      AND (v_q IS NULL OR q.customer_label ILIKE '%' || v_q || '%')
  ),
  open_rows AS (
    -- searching shows every record for that name, gaps or not. Otherwise only gaps.
    SELECT g.*,
           lower(btrim(g.customer_label)) AS household,
           (COALESCE(g.needs_phone, false)::int + COALESCE(g.needs_ecrm, false)::int
            + COALESCE(g.needs_marketing, false)::int + COALESCE(g.needs_referral, false)::int
            + COALESCE(g.needs_issued, false)::int) AS missing_count
    FROM gaps g
     WHERE v_q IS NOT NULL OR g.needs_phone OR g.needs_ecrm OR g.needs_marketing OR g.needs_referral OR g.needs_issued
  ),
  hh AS (
    SELECT o.household,
           max(o.customer_label) AS customer_label,
           max(o.on_date) AS last_date,
           count(*)::int AS record_count,
           SUM(o.missing_count)::int AS missing_count,
           -- Who the records belong to. Usually one person, not always.
           COALESCE(array_agg(DISTINCT o.owner) FILTER (WHERE o.owner IS NOT NULL), ARRAY[]::text[]) AS owners,
           min(lower(o.owner)) AS owner_sort,
           -- What the household already has, so the one box per household knows
           -- whether there is anything left to fill.
           max(o.phone_last4) FILTER (WHERE o.phone_last4 IS NOT NULL) AS phone_last4,
           bool_or(o.needs_phone) AS needs_phone,
           max(o.marketing_source) FILTER (WHERE COALESCE(btrim(o.marketing_source),'') <> '') AS marketing_source,
           bool_or(o.needs_marketing) AS needs_marketing,
           -- One link for the household (Peter 2026-09-20).
           max(o.ecrm) FILTER (WHERE COALESCE(btrim(o.ecrm),'') <> '') AS ecrm,
           bool_or(o.needs_ecrm) AS needs_ecrm,
           bool_or(o.needs_referral) AS needs_referral,
           max(o.referred_by_customer) FILTER (WHERE o.referred_by_customer IS NOT NULL) AS referred_by_customer,
           max(o.sourced_by_team_member_id::text) FILTER (WHERE o.sourced_by_team_member_id IS NOT NULL) AS sourced_by_team_member_id
    FROM open_rows o GROUP BY o.household
  ),
  page AS (
    SELECT z.*, row_number() OVER () AS rn
    FROM (
      SELECT * FROM hh
      ORDER BY
        CASE WHEN v_sort = 'date'     AND v_desc     THEN last_date END DESC NULLS LAST,
        CASE WHEN v_sort = 'date'     AND NOT v_desc THEN last_date END ASC  NULLS LAST,
        CASE WHEN v_sort = 'customer' AND v_desc     THEN lower(customer_label) END DESC NULLS LAST,
        CASE WHEN v_sort = 'customer' AND NOT v_desc THEN lower(customer_label) END ASC  NULLS LAST,
        CASE WHEN v_sort = 'missing'  AND v_desc     THEN missing_count END DESC NULLS LAST,
        CASE WHEN v_sort = 'missing'  AND NOT v_desc THEN missing_count END ASC  NULLS LAST,
        CASE WHEN v_sort = 'owner'    AND v_desc     THEN owner_sort END DESC NULLS LAST,
        CASE WHEN v_sort = 'owner'    AND NOT v_desc THEN owner_sort END ASC  NULLS LAST,
        last_date DESC, customer_label
      LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
    ) z
  )
  SELECT (SELECT count(*) FROM hh), (SELECT count(*) FROM open_rows),
         COALESCE(jsonb_agg(jsonb_build_object(
           'household', h.household, 'customer_label', h.customer_label,
           'last_date', h.last_date, 'record_count', h.record_count, 'missing_count', h.missing_count,
           'owners', to_jsonb(h.owners),
           'phone_last4', h.phone_last4, 'needs_phone', h.needs_phone,
           'marketing_source', h.marketing_source, 'needs_marketing', h.needs_marketing,
           'ecrm', h.ecrm, 'needs_ecrm', h.needs_ecrm,
           'needs_referral', h.needs_referral,
           'referred_by_customer', h.referred_by_customer,
           'sourced_by_team_member_id', h.sourced_by_team_member_id,
           'records', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'kind', o.kind, 'id', o.id, 'customer_label', o.customer_label,
                      'on_date', o.on_date, 'detail', o.detail,
                      'team_member_id', o.team_member_id, 'owner', o.owner,
                      'phone_last4', o.phone_last4, 'ecrm', o.ecrm,
                      'marketing_source', o.marketing_source,
                      'referred_by_customer', o.referred_by_customer,
                      'sourced_by_team_member_id', o.sourced_by_team_member_id,
                      'needs_phone', o.needs_phone, 'needs_ecrm', o.needs_ecrm,
                      'needs_marketing', o.needs_marketing, 'needs_referral', o.needs_referral,
                      'needs_issued', o.needs_issued, 'missing_count', o.missing_count,
                      'policies', o.policies)
                    ORDER BY o.on_date DESC, o.kind, o.id)
               FROM open_rows o WHERE o.household = h.household), '[]'::jsonb)
         ) ORDER BY h.rn), '[]'::jsonb)
    INTO v_households, v_rows, v_out
  FROM page h;

  RETURN jsonb_build_object('ok', true,
                            'total_households', COALESCE(v_households, 0),
                            'total_rows', COALESCE(v_rows, 0),
                            'searching', (v_q IS NOT NULL),
                            'sort', v_sort, 'dir', CASE WHEN v_desc THEN 'desc' ELSE 'asc' END,
                            'households', COALESCE(v_out, '[]'::jsonb));
END $function$;
