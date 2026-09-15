-- What the page lists so a record can be found, edited or removed.
CREATE OR REPLACE FUNCTION public.rp_recent_entries(p_days integer DEFAULT 14, p_team_member_id uuid DEFAULT NULL, p_limit integer DEFAULT 200)
RETURNS TABLE(kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid,
              who text, customer_label text, phone_last4 text, summary text, amount numeric,
              created_at timestamptz, can_change boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_from date; v_week date := public.rp_week_end(public.rp_today_central());
        v_today timestamptz := public.rp_today_central()::timestamptz; v_who uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  v_from := public.rp_today_central() - GREATEST(1, COALESCE(p_days, 14));
  v_who := CASE WHEN a.is_admin THEN p_team_member_id ELSE a.actor_id END;

  RETURN QUERY
  WITH rows AS (
    SELECT 'sale'::text AS kind, s.id, s.submitted_date AS occurred_on, s.week_end_date, s.team_member_id,
           s.customer_label, s.phone_last4,
           (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
              FROM public.sales_log_products p WHERE p.sales_log_id = s.id) AS summary,
           s.total_premium AS amount, s.created_at
      FROM public.sales_log s
     WHERE s.agency_id = a.agency_id AND s.status = 'active' AND s.submitted_date >= v_from
    UNION ALL
    SELECT 'quote', q.id, q.quote_date, q.week_end_date, q.team_member_id, q.customer_label, q.phone_last4,
           (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
              FROM public.quote_log_products p WHERE p.quote_log_id = q.id), NULL::numeric, q.created_at
      FROM public.quote_log q
     WHERE q.agency_id = a.agency_id AND q.status = 'active' AND q.quote_date >= v_from
    UNION ALL
    SELECT 'cancelation', c.id, c.canceled_on, c.week_end_date, c.team_member_id, c.customer_label, c.phone_last4,
           initcap(c.policy_line) || ' ' || COALESCE(c.product_type,''), c.premium, c.created_at
      FROM public.cancelation_log c
     WHERE c.agency_id = a.agency_id AND c.status = 'active' AND c.canceled_on >= v_from
    UNION ALL
    SELECT 'activity', l.id, l.occurred_on, l.week_end_date, l.team_member_id, l.customer_label, l.phone_last4,
           COALESCE(v.label, l.activity_key), l.points, l.created_at
      FROM public.retention_activity_log l
      LEFT JOIN public.retention_point_values v ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
     WHERE l.agency_id = a.agency_id AND l.status <> 'void' AND l.source = 'manual' AND l.occurred_on >= v_from
    UNION ALL
    SELECT 'scorecard', f.id, f.scorecard_date, public.rp_week_end(f.scorecard_date), f.team_member_id,
           public.rp_customer_label(f.customer_first_name, NULL), f.phone_last4,
           'Conversation score ' || COALESCE(round(f.average_score, 1)::text, '—'), f.average_score, f.created_at
      FROM public.fit_scorecards f
     WHERE f.agency_id = a.agency_id AND f.scorecard_date >= v_from
  )
  SELECT r.kind, r.id, r.occurred_on, r.week_end_date, r.team_member_id,
         COALESCE(t.nickname, t.first_name, 'Unknown') AS who,
         r.customer_label, r.phone_last4, btrim(COALESCE(r.summary, '')) AS summary, r.amount, r.created_at,
         (a.is_admin OR (r.team_member_id = a.actor_id AND (r.week_end_date >= v_week OR r.created_at >= v_today))) AS can_change
    FROM rows r
    LEFT JOIN public.team t ON t.id = r.team_member_id
   WHERE (v_who IS NULL OR r.team_member_id = v_who)
   ORDER BY r.occurred_on DESC, r.created_at DESC
   LIMIT GREATEST(1, COALESCE(p_limit, 200));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_recent_entries(integer, uuid, integer) TO authenticated;
