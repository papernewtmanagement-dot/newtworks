-- Peter 2026-09-19: History needs the ECRM link on the row, the same way the
-- spot-check has it, so a record can be checked against the opportunity
-- without leaving the tab. rp_entry_rows already carries the link; the
-- History function just was not passing it through. A function's return shape
-- cannot be widened in place, so it is dropped and rebuilt.

DROP FUNCTION IF EXISTS public.rp_recent_entries(integer, uuid, integer, text, date, date, text);

CREATE FUNCTION public.rp_recent_entries(
  p_days integer DEFAULT 14,
  p_team_member_id uuid DEFAULT NULL::uuid,
  p_limit integer DEFAULT 200,
  p_search text DEFAULT NULL::text,
  p_from date DEFAULT NULL::date,
  p_to date DEFAULT NULL::date,
  p_kind text DEFAULT NULL::text
)
RETURNS TABLE(kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid,
              who text, customer_label text, phone_last4 text, summary text, amount numeric,
              issued_amount numeric, ecrm_url text,
              created_at timestamp with time zone, entry_source text, can_change boolean)
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

  v_from := CASE WHEN p_from IS NOT NULL THEN p_from
                 WHEN v_q IS NOT NULL THEN DATE '1900-01-01'
                 ELSE public.rp_today_central() - GREATEST(1, COALESCE(p_days, 14)) END;
  v_to := COALESCE(p_to, DATE '9999-12-31');
  v_who := CASE WHEN a.is_admin THEN p_team_member_id ELSE a.actor_id END;

  RETURN QUERY
  SELECT r.kind, r.id, r.occurred_on, r.week_end_date, r.team_member_id,
         COALESCE(t.nickname, t.first_name, 'Unknown') AS who,
         r.customer_label, r.phone_last4, btrim(COALESCE(r.summary, '')) AS summary,
         r.amount, r.issued_amount, r.ecrm_url, r.created_at,
         r.entry_source,
         (a.is_admin OR (r.team_member_id = a.actor_id AND (r.week_end_date >= v_week OR r.created_at >= v_today))) AS can_change
    FROM public.rp_entry_rows(a.agency_id, v_from, v_to, false) r
    LEFT JOIN public.team t ON t.id = r.team_member_id
   WHERE (v_who IS NULL OR r.team_member_id = v_who)
     AND (v_kind IS NULL OR r.kind = v_kind)
     AND (v_q IS NULL
          OR r.customer_label ILIKE '%' || v_q || '%'
          OR (v_digits IS NOT NULL AND r.phone_last4 = right(v_digits, 4)))
   ORDER BY r.occurred_on DESC, r.created_at DESC
   LIMIT GREATEST(1, COALESCE(p_limit, 200));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_recent_entries(integer, uuid, integer, text, date, date, text) TO authenticated;
