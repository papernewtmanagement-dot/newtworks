-- Peter 2026-09-20, two things.
--
-- 1) The spot-check still picks households off THIS week's checkable rows, but
--    once a household is picked it now shows everything that household has:
--    prior weeks, backfill, and the credits a sale wrote on its own. Same
--    builder, two modes -- rp_spot_check_pool with no household list is the
--    week's pool (unchanged), with a household list it is that household's
--    whole history. in_scope says whether a row is one he can act on.
--
-- 2) A note is required on a logged activity at entry, but the edit screen
--    could blank it afterwards. The link and the review site were already
--    protected on the way out; the note was not. It is now.

DROP FUNCTION IF EXISTS public.rp_spot_check_pool(date);

CREATE FUNCTION public.rp_spot_check_pool(p_week_end date, p_households text[] DEFAULT NULL)
RETURNS TABLE(
  id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
  occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
  phone_last4 text, note text, ecrm_url text, points numeric, premium numeric,
  spot_check_note text, in_scope boolean, verified_at timestamptz, entry_source text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  wk AS (SELECT public.rp_week_end(p_week_end) AS week_end),
  acts AS (
    SELECT l.id, 'activity'::text AS kind, l.team_member_id, t.first_name, l.activity_key,
           v.label, l.occurred_on, l.customer_label, l.customer_first_name, l.customer_last_initial,
           l.phone_last4,
           CASE WHEN l.review_platform IS NULL THEN l.note
                ELSE initcap(l.review_platform) || COALESCE(' - ' || l.note, '') END AS note,
           l.ecrm_url, l.points, NULL::numeric AS premium, l.spot_check_note,
           (l.verified_at IS NULL
            AND COALESCE(v.category, 'logged') = 'logged'
            AND COALESCE(v.spot_checkable, true)
            AND l.created_by IS NOT NULL
            AND l.created_by = l.team_member_id) AS in_scope,
           l.verified_at, COALESCE(l.source, 'manual') AS entry_source,
           (public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk)) AS in_week
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
      LEFT JOIN public.team_directory t ON t.id = l.team_member_id
      LEFT JOIN public.retention_point_values v
        ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
     WHERE l.status = 'credited'
  ),
  sale_products AS (
    SELECT sp.sales_log_id,
           min(sp.issued_date) AS issued_on,
           sum(COALESCE(sp.issued_premium, sp.premium, 0)) AS premium,
           string_agg(DISTINCT initcap(sp.line_of_business), ', ') AS lines,
           bool_or(sp.issued_date IS NOT NULL
                   AND public.rp_week_end(sp.issued_date) = (SELECT week_end FROM wk)) AS issued_this_week
      FROM public.sales_log_products sp
      JOIN me ON me.agency_id = sp.agency_id
     GROUP BY sp.sales_log_id
  ),
  sales AS (
    SELECT s.id, 'sale'::text AS kind, s.team_member_id, t.first_name, 'sale'::text AS activity_key,
           'Sale - ' || COALESCE(p.lines, 'policy') AS label,
           COALESCE(p.issued_on, s.submitted_date) AS occurred_on,
           s.customer_label, s.customer_first_name, s.customer_last_initial,
           s.phone_last4, s.note, s.ecrm_opportunity_url AS ecrm_url,
           NULL::numeric AS points, p.premium, s.spot_check_note,
           (s.verified_at IS NULL
            AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
            AND (s.created_by IS NULL OR s.created_by = s.team_member_id)) AS in_scope,
           s.verified_at, COALESCE(s.entry_source, 'manual') AS entry_source,
           COALESCE(p.issued_this_week, false) AS in_week
      FROM public.sales_log s
      JOIN sale_products p ON p.sales_log_id = s.id
      JOIN me ON me.agency_id = s.agency_id
      LEFT JOIN public.team_directory t ON t.id = s.team_member_id
     WHERE s.status = 'active'
  ),
  every_row AS (
    SELECT * FROM acts
    UNION ALL
    SELECT * FROM sales
  )
  SELECT e.id, e.kind, e.team_member_id, e.first_name, e.activity_key, e.label, e.occurred_on,
         e.customer_label, e.customer_first_name, e.customer_last_initial, e.phone_last4,
         e.note, e.ecrm_url, e.points, e.premium, e.spot_check_note,
         e.in_scope, e.verified_at, e.entry_source
    FROM every_row e
   WHERE public.is_agency_admin()
     AND CASE
           WHEN p_households IS NULL THEN (e.in_scope AND e.in_week)
           ELSE (lower(btrim(COALESCE(e.customer_label, ''))) || '|' || COALESCE(e.phone_last4, ''))
                = ANY (p_households)
         END;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_pool(date, text[]) TO authenticated;

DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);

CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(
  id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
  occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
  phone_last4 text, note text, ecrm_url text, points numeric, premium numeric,
  spot_check_note text, in_scope boolean, verified_at timestamptz, entry_source text,
  remaining integer, households_left integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end)),
  risk AS (
    SELECT l.activity_key,
           (count(*) FILTER (WHERE l.status = 'void') + 1)::numeric / (count(*) + 8) AS w
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
     GROUP BY l.activity_key
    UNION ALL
    SELECT 'sale',
           (count(*) FILTER (WHERE s.status = 'void') + 1)::numeric / (count(*) + 8)
      FROM public.sales_log s
      JOIN me ON me.agency_id = s.agency_id
     WHERE COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
  ),
  hh AS (
    SELECT lower(btrim(COALESCE(p.customer_label, ''))) AS key, COALESCE(p.phone_last4, '') AS ph,
           max(COALESCE(r.w, 1.0 / 9)) AS w
      FROM pool p LEFT JOIN risk r ON r.activity_key = p.activity_key
     GROUP BY 1, 2
  ),
  picked AS (
    SELECT h.key, h.ph FROM hh h
     ORDER BY power(
       ((('x' || substr(md5(h.key || h.ph || public.rp_week_end(p_week_end)::text), 1, 8))::bit(32)::int::numeric
         + 2147483648) / 4294967296.0),
       1.0 / GREATEST(h.w, 0.01)) DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50))
  ),
  -- Everything those households have ever had, not just this week's rows.
  full_rows AS (
    SELECT * FROM public.rp_spot_check_pool(
      p_week_end,
      (SELECT COALESCE(array_agg(k.key || '|' || k.ph), ARRAY[]::text[]) FROM picked k))
  )
  SELECT f.id, f.kind, f.team_member_id, f.first_name, f.activity_key, f.label, f.occurred_on,
         f.customer_label, f.customer_first_name, f.customer_last_initial, f.phone_last4,
         f.note, f.ecrm_url, f.points, f.premium, f.spot_check_note,
         f.in_scope, f.verified_at, f.entry_source,
         (SELECT count(*) FROM pool)::integer,
         (SELECT count(*) FROM hh)::integer
    FROM full_rows f
   ORDER BY lower(btrim(COALESCE(f.customer_label, ''))), COALESCE(f.phone_last4, ''),
            f.occurred_on, f.label;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;

-- The note cannot be cleared off something that requires it.
CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date;
BEGIN
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'that entry was removed. Log it again instead.'; END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — change the sale instead'; END IF;
  IF c ? 'activity_key' AND c->>'activity_key' IS DISTINCT FROM r.activity_key THEN
    RAISE EXCEPTION 'to change which activity it was, remove this one and log the right one';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.retention_activity_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    occurred_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    credited_week_end_date = CASE WHEN credited_week_end_date IS NULL THEN NULL ELSE public.rp_week_end(v_on) END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    policy_line  = CASE WHEN c ? 'policy_line'  THEN NULLIF(lower(btrim(COALESCE(c->>'policy_line',''))),'') ELSE policy_line END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    save_line    = CASE WHEN c ? 'save_line'   THEN NULLIF(lower(btrim(COALESCE(c->>'save_line',''))),'') ELSE save_line END,
    save_reason  = CASE WHEN c ? 'save_reason' THEN NULLIF(btrim(COALESCE(c->>'save_reason','')),'') ELSE save_reason END,
    review_platform = CASE WHEN c ? 'review_platform' THEN NULLIF(lower(btrim(COALESCE(c->>'review_platform',''))),'') ELSE review_platform END,
    updated_at = now()
  WHERE id = p_id;
  -- The link cannot be cleared off something that requires it.
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL) THEN
    RAISE EXCEPTION 'this one needs the ECRM link, so it cannot be cleared';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_platform AND l.review_platform IS NULL) THEN
    RAISE EXCEPTION 'this one needs the site the review was left on, so it cannot be cleared';
  END IF;
  -- Same for the note. It is required when the entry is logged, so an edit
  -- must not be able to empty it out afterwards (Peter 2026-09-20).
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_note
                AND l.note IS NULL AND l.save_reason IS NULL) THEN
    RAISE EXCEPTION 'this one needs a note on what you covered, so it cannot be cleared';
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;
