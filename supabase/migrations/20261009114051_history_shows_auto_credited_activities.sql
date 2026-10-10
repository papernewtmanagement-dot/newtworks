CREATE OR REPLACE FUNCTION public.rp_recent_entries(p_days integer DEFAULT 14, p_team_member_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200, p_search text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_kind text DEFAULT NULL::text)
 RETURNS TABLE(kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid, who text, customer_label text, phone_last4 text, summary text, amount numeric, issued_amount numeric, ecrm_url text, created_at timestamp with time zone, entry_source text, can_change boolean, can_note boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_from date; v_to date; v_week date := public.rp_week_end(public.rp_today_central());
        v_today timestamptz := public.rp_today_central()::timestamptz; v_who uuid;
        v_q text; v_digits text; v_kind text;
BEGIN
  PERFORM public.require_login('staff');
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
         -- Peter 2026-10-09: credits the system makes off a sale, quote or cancel
         -- (referral sold, multiline, autopay, pivot, cancelation logged) show in
         -- History too. They change with the record they came from, so no Edit/Delete.
         CASE WHEN COALESCE((r.meta->>'derived')::boolean, false) THEN 'auto' ELSE r.entry_source END AS entry_source,
         (NOT COALESCE((r.meta->>'derived')::boolean, false))
           AND public.rp_entry_can_change(r.team_member_id, r.created_at) AS can_change,
         public.rp_entry_can_note(r.team_member_id, CASE WHEN r.kind = 'appointment'
           THEN (SELECT x.escalated_to_team_member_id FROM public.appointment_log x WHERE x.id = r.id) END) AS can_note
    FROM public.rp_entry_rows(a.agency_id, DATE '1900-01-01', DATE '9999-12-31', true) r
    LEFT JOIN public.team t ON t.id = r.team_member_id
   WHERE (v_who IS NULL OR r.team_member_id = v_who)
     AND (r.occurred_on BETWEEN v_from AND v_to
          OR (r.created_at AT TIME ZONE 'America/Chicago')::date BETWEEN v_from AND v_to)
     AND (v_kind IS NULL OR r.kind = v_kind)
     AND (v_q IS NULL
          OR r.customer_label ILIKE '%' || v_q || '%'
          OR (v_digits IS NOT NULL AND r.phone_last4 = right(v_digits, 4)))
   ORDER BY r.occurred_on DESC, r.created_at DESC
   LIMIT GREATEST(1, COALESCE(p_limit, 200));
END $function$;
