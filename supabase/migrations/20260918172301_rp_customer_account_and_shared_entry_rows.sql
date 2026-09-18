-- ---------------------------------------------------------------
-- One place that turns the five production tables into one row per
-- logged record. rp_recent_entries used to carry this union inline;
-- rp_customer_account needs the same union with a different filter,
-- so the union moves here and both call it. One function per job.
--
-- p_include_derived: activities the system wrote off a sale (multiline,
-- autopay) are hidden from the History tab, which only shows what a
-- person logged. The customer account shows them, because they are part
-- of that household's record.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_entry_rows(
  p_agency uuid,
  p_from date,
  p_to date,
  p_include_derived boolean DEFAULT false
)
RETURNS TABLE(
  kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid,
  customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text,
  summary text, amount numeric, created_at timestamptz, entry_source text,
  note text, ecrm_url text, meta jsonb
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT 'sale'::text, s.id, s.submitted_date, s.week_end_date, s.team_member_id,
         s.customer_label::text, s.customer_first_name::text, s.customer_last_initial::text, s.phone_last4::text,
         (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
            FROM public.sales_log_products p WHERE p.sales_log_id = s.id)::text,
         s.total_premium, s.created_at, COALESCE(s.entry_source,'manual')::text,
         s.note::text, s.ecrm_opportunity_url::text,
         jsonb_build_object('relationship', s.household_status, 'marketing_source', s.marketing_source,
                            'cars', s.vehicle_count, 'on_file_answer', s.on_file_answer)
    FROM public.sales_log s
   WHERE s.agency_id = p_agency AND s.status = 'active'
     AND s.submitted_date >= p_from AND s.submitted_date <= p_to
  UNION ALL
  SELECT 'quote'::text, q.id, q.quote_date, q.week_end_date, q.team_member_id,
         q.customer_label::text, q.customer_first_name::text, q.customer_last_initial::text, q.phone_last4::text,
         (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
            FROM public.quote_log_products p WHERE p.quote_log_id = q.id)::text,
         NULL::numeric, q.created_at, 'manual'::text,
         q.note::text, q.ecrm_opportunity_url::text,
         jsonb_build_object('relationship', q.relationship_type, 'marketing_source', q.marketing_source)
    FROM public.quote_log q
   WHERE q.agency_id = p_agency AND q.status = 'active'
     AND q.quote_date >= p_from AND q.quote_date <= p_to
  UNION ALL
  SELECT 'cancelation'::text, c.id, c.canceled_on, c.week_end_date, c.team_member_id,
         c.customer_label::text, c.customer_first_name::text, c.customer_last_initial::text, c.phone_last4::text,
         (initcap(c.policy_line) || ' ' || COALESCE(c.product_type,''))::text,
         c.premium, c.created_at, 'manual'::text,
         c.note::text, NULL::text,
         jsonb_build_object('reason', c.reason, 'replacement', c.is_replacement,
                            'chargeback', c.chargeback_points, 'cars', c.vehicle_count)
    FROM public.cancelation_log c
   WHERE c.agency_id = p_agency AND c.status = 'active'
     AND c.canceled_on >= p_from AND c.canceled_on <= p_to
  UNION ALL
  SELECT 'activity'::text, l.id, l.occurred_on, l.week_end_date, l.team_member_id,
         l.customer_label::text, l.customer_first_name::text, l.customer_last_initial::text, l.phone_last4::text,
         COALESCE(v.label, l.activity_key)::text,
         l.points, l.created_at, 'manual'::text,
         l.note::text, l.ecrm_url::text,
         jsonb_build_object('activity_key', l.activity_key, 'derived', (l.source <> 'manual'),
                            'line', l.policy_line, 'product', l.product_type, 'premium', l.premium,
                            'save_reason', l.save_reason, 'clears_on', l.credit_available_on)
    FROM public.retention_activity_log l
    LEFT JOIN public.retention_point_values v
      ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
   WHERE l.agency_id = p_agency AND l.status <> 'void'
     AND (p_include_derived OR l.source = 'manual')
     AND l.occurred_on >= p_from AND l.occurred_on <= p_to
  UNION ALL
  SELECT 'scorecard'::text, f.id, f.scorecard_date, public.rp_week_end(f.scorecard_date), f.team_member_id,
         NULLIF(btrim(COALESCE(f.customer_first_name,'')), '')::text,
         NULLIF(btrim(COALESCE(f.customer_first_name,'')), '')::text,
         NULL::text, f.phone_last4::text,
         ('Conversation score ' || COALESCE(round(f.average_score, 1)::text, '—'))::text,
         f.average_score, f.created_at, 'manual'::text,
         f.notes::text, NULL::text,
         jsonb_build_object('average', f.average_score, 'opportunity', f.opportunity_ref)
    FROM public.fit_scorecards f
   WHERE f.agency_id = p_agency
     AND f.scorecard_date >= p_from AND f.scorecard_date <= p_to;
$function$;

REVOKE EXECUTE ON FUNCTION public.rp_entry_rows(uuid, date, date, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_entry_rows(uuid, date, date, boolean) FROM anon, authenticated;

-- ---------------------------------------------------------------
-- History tab. Same output as before; the union now comes from
-- rp_entry_rows so the account view and this stay in step.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_recent_entries(
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

  -- A date typed in the From box wins. Otherwise a search reaches all the way
  -- back, and with neither the rolling window stands.
  v_from := CASE WHEN p_from IS NOT NULL THEN p_from
                 WHEN v_q IS NOT NULL THEN DATE '1900-01-01'
                 ELSE public.rp_today_central() - GREATEST(1, COALESCE(p_days, 14)) END;
  v_to := COALESCE(p_to, DATE '9999-12-31');
  v_who := CASE WHEN a.is_admin THEN p_team_member_id ELSE a.actor_id END;

  RETURN QUERY
  SELECT r.kind, r.id, r.occurred_on, r.week_end_date, r.team_member_id,
         COALESCE(t.nickname, t.first_name, 'Unknown') AS who,
         r.customer_label, r.phone_last4, btrim(COALESCE(r.summary, '')) AS summary, r.amount, r.created_at,
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

-- ---------------------------------------------------------------
-- One household's whole account: who they are, the policies on file,
-- and every record touching them, newest first.
--
-- Household key is first name + last initial + phone last four, the
-- same key the log uses. Rows older than the phone rule have no phone
-- and match any phone, so they still show up.
--
-- p_label is what the screen shows ("Anna S."). A conversation score
-- carries only a first name, so the initial is optional on both sides.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_customer_account(
  p_label text,
  p_phone_last4 text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_label text; v_first text; v_initial text; v_phone text; v_out jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  v_label := btrim(COALESCE(p_label, ''));
  IF v_label = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'No customer given.'); END IF;

  IF v_label ~ '\s[A-Za-z]\.$' THEN
    v_first   := btrim(left(v_label, length(v_label) - 3));
    v_initial := upper(substr(v_label, length(v_label) - 1, 1));
  ELSE
    v_first   := v_label;
    v_initial := NULL;
  END IF;
  v_phone := NULLIF(btrim(COALESCE(p_phone_last4, '')), '');

  WITH ent AS (
    SELECT r.*
      FROM public.rp_entry_rows(a.agency_id, DATE '1900-01-01', DATE '9999-12-31', true) r
     WHERE lower(btrim(COALESCE(r.customer_first_name, ''))) = lower(v_first)
       AND (v_initial IS NULL OR r.customer_last_initial IS NULL OR upper(r.customer_last_initial) = v_initial)
       AND (v_phone IS NULL OR r.phone_last4 IS NULL OR r.phone_last4 = v_phone)
  ),
  appt AS (
    SELECT 'appointment'::text AS kind, ap.id,
           COALESCE((ap.starts_at AT TIME ZONE 'America/Chicago')::date, ap.set_on) AS occurred_on,
           ap.week_end_date, ap.team_member_id,
           ap.customer_label::text, ap.customer_first_name::text, ap.customer_last_initial::text, ap.phone_last4::text,
           (CASE WHEN ap.sold_on IS NOT NULL THEN 'Appointment sold'
                 WHEN ap.no_show_on IS NOT NULL THEN 'Appointment no show'
                 WHEN ap.kept_on IS NOT NULL THEN 'Appointment kept'
                 ELSE 'Appointment set' END
            || CASE WHEN ap.line_of_business IS NOT NULL
                    THEN ' · ' || initcap(ap.line_of_business) || ' ' || COALESCE(ap.product_type, '')
                    ELSE '' END)::text AS summary,
           NULL::numeric AS amount, ap.created_at, 'manual'::text AS entry_source,
           ap.note::text, ap.ecrm_url::text,
           jsonb_build_object('set_on', ap.set_on, 'kept_on', ap.kept_on, 'no_show_on', ap.no_show_on,
                              'sold_on', ap.sold_on, 'starts_at', ap.starts_at, 'is_video', ap.is_video) AS meta
      FROM public.appointment_log ap
     WHERE ap.agency_id = a.agency_id AND ap.status = 'active'
       AND lower(btrim(COALESCE(ap.customer_first_name, ''))) = lower(v_first)
       AND (v_initial IS NULL OR ap.customer_last_initial IS NULL OR upper(ap.customer_last_initial) = v_initial)
       AND (v_phone IS NULL OR ap.phone_last4 IS NULL OR ap.phone_last4 = v_phone)
  ),
  tl AS (
    SELECT x.kind, x.id, x.occurred_on, x.team_member_id, x.customer_label, x.phone_last4,
           btrim(COALESCE(x.summary, '')) AS summary, x.amount, x.created_at, x.entry_source,
           x.note, x.ecrm_url, x.meta
      FROM ent x
    UNION ALL
    SELECT x.kind, x.id, x.occurred_on, x.team_member_id, x.customer_label, x.phone_last4,
           btrim(COALESCE(x.summary, '')), x.amount, x.created_at, x.entry_source,
           x.note, x.ecrm_url, x.meta
      FROM appt x
  ),
  tl2 AS (
    SELECT tl.kind, tl.id, tl.occurred_on, tl.summary, tl.amount, tl.created_at,
           tl.entry_source, tl.note, tl.ecrm_url, tl.meta, tl.customer_label, tl.phone_last4,
           COALESCE(t.nickname, t.first_name, 'Unknown') AS who
      FROM tl LEFT JOIN public.team t ON t.id = tl.team_member_id
  ),
  pol AS (
    SELECT sp.id AS sale_product_id, s.id AS sale_id,
           sp.line_of_business, sp.product_type, sp.premium, sp.vehicle_count, sp.policy_count,
           s.submitted_date, sp.issued_date, sp.issued_premium,
           COALESCE(sp.autopay_enrolled, false) AS autopay_enrolled,
           COALESCE(sp.is_added_to_existing, false) AS is_added_to_existing,
           COALESCE(t.nickname, t.first_name, 'Unknown') AS sold_by,
           (SELECT c.canceled_on FROM public.cancelation_log c
             WHERE c.matched_sale_product_id = sp.id AND c.status = 'active'
             ORDER BY c.canceled_on DESC LIMIT 1) AS canceled_on
      FROM public.sales_log s
      JOIN public.sales_log_products sp ON sp.sales_log_id = s.id
      LEFT JOIN public.team t ON t.id = s.team_member_id
     WHERE s.agency_id = a.agency_id AND s.status = 'active'
       AND lower(btrim(COALESCE(s.customer_first_name, ''))) = lower(v_first)
       AND (v_initial IS NULL OR s.customer_last_initial IS NULL OR upper(s.customer_last_initial) = v_initial)
       AND (v_phone IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = v_phone)
  )
  SELECT jsonb_build_object(
    'ok', true,
    'customer', jsonb_build_object(
      'label', COALESCE((SELECT e.customer_label FROM ent e WHERE e.customer_label ~ '\s[A-Za-z]\.$' LIMIT 1), v_label),
      'first_name', v_first,
      'last_initial', v_initial,
      'phone_last4', v_phone,
      'first_seen', (SELECT min(x.occurred_on) FROM tl x),
      'last_seen', (SELECT max(x.occurred_on) FROM tl x),
      'relationship', (SELECT e.meta->>'relationship' FROM ent e
                        WHERE e.kind IN ('sale','quote') AND e.meta->>'relationship' IS NOT NULL
                        ORDER BY e.occurred_on DESC LIMIT 1),
      'marketing_source', (SELECT e.meta->>'marketing_source' FROM ent e
                            WHERE e.meta->>'marketing_source' IS NOT NULL
                            ORDER BY e.occurred_on DESC LIMIT 1),
      'phones', COALESCE((SELECT jsonb_agg(DISTINCT x.phone_last4) FROM tl x WHERE x.phone_last4 IS NOT NULL), '[]'::jsonb)
    ),
    'totals', jsonb_build_object(
      'sales', (SELECT count(*) FROM ent e WHERE e.kind = 'sale'),
      'quotes', (SELECT count(*) FROM ent e WHERE e.kind = 'quote'),
      'cancelations', (SELECT count(*) FROM ent e WHERE e.kind = 'cancelation'),
      'activities', (SELECT count(*) FROM ent e WHERE e.kind = 'activity'),
      'appointments', (SELECT count(*) FROM appt),
      'retention_points', COALESCE((SELECT sum(e.amount) FROM ent e WHERE e.kind = 'activity'), 0),
      'policies', (SELECT count(*) FROM pol),
      'policies_in_force', (SELECT count(*) FROM pol p WHERE p.canceled_on IS NULL),
      'premium_in_force', COALESCE((SELECT sum(COALESCE(p.issued_premium, p.premium)) FROM pol p WHERE p.canceled_on IS NULL), 0)
    ),
    'policies', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.submitted_date DESC, p.line_of_business) FROM pol p), '[]'::jsonb),
    'timeline', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.occurred_on DESC, x.created_at DESC) FROM tl2 x), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_customer_account(text, text) TO authenticated;

-- Voided activities were leaking into the name suggestions: the status
-- value is 'void', not 'voided', so the filter never matched anything.
CREATE OR REPLACE FUNCTION public.rp_customer_suggest2(p_prefix text)
RETURNS TABLE(customer_first_name text, customer_last_initial text, customer_label text, phone_last4 text, policies_on_file integer, last_seen date)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  seen AS (
    SELECT s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4, s.submitted_date AS d, 1 AS pol
      FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id WHERE s.status = 'active'
    UNION ALL
    SELECT q.customer_first_name, q.customer_last_initial, q.customer_label, q.phone_last4, q.quote_date, 0
      FROM public.quote_log q JOIN me ON me.agency_id = q.agency_id WHERE q.status = 'active'
    UNION ALL
    SELECT l.customer_first_name, l.customer_last_initial, l.customer_label, l.phone_last4, l.occurred_on, 0
      FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id WHERE l.status <> 'void'
    UNION ALL
    SELECT c.customer_first_name, c.customer_last_initial, c.customer_label, c.phone_last4, c.canceled_on, 0
      FROM public.cancelation_log c JOIN me ON me.agency_id = c.agency_id WHERE c.status = 'active'
  )
  SELECT customer_first_name, customer_last_initial, customer_label, phone_last4,
         SUM(pol)::int AS policies_on_file, MAX(d) AS last_seen
  FROM seen
  WHERE auth.uid() IS NOT NULL AND customer_label IS NOT NULL AND lower(customer_label) LIKE lower(btrim(p_prefix)) || '%'
  GROUP BY 1, 2, 3, 4
  ORDER BY MAX(d) DESC, customer_label
  LIMIT 8;
$function$;
