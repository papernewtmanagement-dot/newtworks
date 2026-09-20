-- Peter 2026-09-20: the backfill list is by household, not by row. A household
-- is one card. The phone and the marketing source are filled once for the whole
-- household; the ECRM link and the issued premium stay per record because they
-- belong to that record. Paging counts households so a household is never split
-- across two pages.

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
  IF v_sort NOT IN ('date','customer','missing') THEN v_sort := 'date'; END IF;

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
           -- What the household already has, so the one box per household knows
           -- whether there is anything left to fill.
           max(o.phone_last4) FILTER (WHERE o.phone_last4 IS NOT NULL) AS phone_last4,
           bool_or(o.needs_phone) AS needs_phone,
           max(o.marketing_source) FILTER (WHERE COALESCE(btrim(o.marketing_source),'') <> '') AS marketing_source,
           bool_or(o.needs_marketing) AS needs_marketing,
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
        last_date DESC, customer_label
      LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
    ) z
  )
  SELECT (SELECT count(*) FROM hh), (SELECT count(*) FROM open_rows),
         COALESCE(jsonb_agg(jsonb_build_object(
           'household', h.household, 'customer_label', h.customer_label,
           'last_date', h.last_date, 'record_count', h.record_count, 'missing_count', h.missing_count,
           'phone_last4', h.phone_last4, 'needs_phone', h.needs_phone,
           'marketing_source', h.marketing_source, 'needs_marketing', h.needs_marketing,
           'needs_referral', h.needs_referral,
           'referred_by_customer', h.referred_by_customer,
           'sourced_by_team_member_id', h.sourced_by_team_member_id,
           'records', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'kind', o.kind, 'id', o.id, 'customer_label', o.customer_label,
                      'on_date', o.on_date, 'detail', o.detail,
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

-- The marketing source belongs to the household the same way the phone does, so
-- filling it on one record fills every record under that name that has none.
CREATE OR REPLACE FUNCTION public.rp_backfill_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; rec jsonb; v_id uuid; v_kind text; v_label text;
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

    -- Same for the marketing source (Peter 2026-09-20). Only rows that have
    -- none are filled; nothing already answered is overwritten.
    IF v_src IS NOT NULL AND v_label IS NOT NULL THEN
      UPDATE public.sales_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND COALESCE(btrim(marketing_source), '') = '';
      GET DIAGNOSTICS n = ROW_COUNT; v_spread := v_spread + n;

      UPDATE public.quote_log SET marketing_source = v_src, updated_at = now()
       WHERE agency_id = a.agency_id AND status = 'active' AND customer_label = v_label
         AND COALESCE(btrim(marketing_source), '') = '';
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
