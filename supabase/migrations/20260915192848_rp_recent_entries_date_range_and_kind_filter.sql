-- Browsing records used to need a customer name: with no search the list only
-- reached back 14 days, so an older row could not be found unless you already
-- knew who it belonged to. Adds a date range and a record-type filter. Same
-- function, same one place the list is built — no second implementation.
DROP FUNCTION IF EXISTS public.rp_recent_entries(integer, uuid, integer, text);

CREATE OR REPLACE FUNCTION public.rp_recent_entries(
  p_days integer DEFAULT 14,
  p_team_member_id uuid DEFAULT NULL::uuid,
  p_limit integer DEFAULT 200,
  p_search text DEFAULT NULL::text,
  p_from date DEFAULT NULL::date,
  p_to date DEFAULT NULL::date,
  p_kind text DEFAULT NULL::text)
 RETURNS TABLE(kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid, who text, customer_label text, phone_last4 text, summary text, amount numeric, created_at timestamp with time zone, entry_source text, can_change boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_from date; v_to date; v_week date := public.rp_week_end(public.rp_today_central());
        v_today timestamptz := public.rp_today_central()::timestamptz; v_who uuid;
        v_q text; v_digits text; v_kind text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  v_q := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_digits := NULLIF(regexp_replace(COALESCE(v_q, ''), '\D', '', 'g'), '');
  v_kind := NULLIF(btrim(lower(COALESCE(p_kind, ''))), '');

  -- A date typed in the From box wins. Otherwise a search reaches all the way
  -- back, and with neither the rolling window stands.
  v_from := CASE WHEN p_from IS NOT NULL THEN p_from
                 WHEN v_q IS NOT NULL THEN DATE '1900-01-01'
                 ELSE public.rp_today_central() - GREATEST(1, COALESCE(p_days, 14)) END;
  v_to := COALESCE(p_to, DATE '9999-12-31');
  v_who := CASE WHEN a.is_admin THEN p_team_member_id ELSE a.actor_id END;

  RETURN QUERY
  WITH rows AS (
    SELECT 'sale'::text AS kind, s.id, s.submitted_date AS occurred_on, s.week_end_date, s.team_member_id,
           s.customer_label, s.phone_last4,
           (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
              FROM public.sales_log_products p WHERE p.sales_log_id = s.id) AS summary,
           s.total_premium AS amount, s.created_at, COALESCE(s.entry_source, 'manual')::text AS entry_source
      FROM public.sales_log s
     WHERE s.agency_id = a.agency_id AND s.status = 'active'
       AND s.submitted_date >= v_from AND s.submitted_date <= v_to
    UNION ALL
    SELECT 'quote', q.id, q.quote_date, q.week_end_date, q.team_member_id, q.customer_label, q.phone_last4,
           (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
              FROM public.quote_log_products p WHERE p.quote_log_id = q.id), NULL::numeric, q.created_at, 'manual'::text
      FROM public.quote_log q
     WHERE q.agency_id = a.agency_id AND q.status = 'active'
       AND q.quote_date >= v_from AND q.quote_date <= v_to
    UNION ALL
    SELECT 'cancelation', c.id, c.canceled_on, c.week_end_date, c.team_member_id, c.customer_label, c.phone_last4,
           initcap(c.policy_line) || ' ' || COALESCE(c.product_type,''), c.premium, c.created_at, 'manual'::text
      FROM public.cancelation_log c
     WHERE c.agency_id = a.agency_id AND c.status = 'active'
       AND c.canceled_on >= v_from AND c.canceled_on <= v_to
    UNION ALL
    SELECT 'activity', l.id, l.occurred_on, l.week_end_date, l.team_member_id, l.customer_label, l.phone_last4,
           COALESCE(v.label, l.activity_key), l.points, l.created_at, 'manual'::text
      FROM public.retention_activity_log l
      LEFT JOIN public.retention_point_values v ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
     WHERE l.agency_id = a.agency_id AND l.status <> 'void' AND l.source = 'manual'
       AND l.occurred_on >= v_from AND l.occurred_on <= v_to
    UNION ALL
    SELECT 'scorecard', f.id, f.scorecard_date, public.rp_week_end(f.scorecard_date), f.team_member_id,
           NULLIF(btrim(COALESCE(f.customer_first_name, '')), ''),
           f.phone_last4,
           'Conversation score ' || COALESCE(round(f.average_score, 1)::text, '—'), f.average_score, f.created_at, 'manual'::text
      FROM public.fit_scorecards f
     WHERE f.agency_id = a.agency_id
       AND f.scorecard_date >= v_from AND f.scorecard_date <= v_to
  )
  SELECT r.kind, r.id, r.occurred_on, r.week_end_date, r.team_member_id,
         COALESCE(t.nickname, t.first_name, 'Unknown') AS who,
         r.customer_label, r.phone_last4, btrim(COALESCE(r.summary, '')) AS summary, r.amount, r.created_at,
         r.entry_source,
         (a.is_admin OR (r.team_member_id = a.actor_id AND (r.week_end_date >= v_week OR r.created_at >= v_today))) AS can_change
    FROM rows r
    LEFT JOIN public.team t ON t.id = r.team_member_id
   WHERE (v_who IS NULL OR r.team_member_id = v_who)
     AND (v_kind IS NULL OR r.kind = v_kind)
     AND (v_q IS NULL
          OR r.customer_label ILIKE '%' || v_q || '%'
          OR (v_digits IS NOT NULL AND r.phone_last4 = right(v_digits, 4)))
   ORDER BY r.occurred_on DESC, r.created_at DESC
   LIMIT GREATEST(1, COALESCE(p_limit, 200));
END $function$;
