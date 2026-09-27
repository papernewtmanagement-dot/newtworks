-- Spot-check fixes (Peter 2026-09-26, evening).
-- 1. A household stays on To check until every record in its file that is open to checking is done. It used to
--    drop off once its in-week records were verified, even with a record from another week still open (Jacob R.
--    1599: the autopay was verified and the household vanished with the fire sale still open), then came back in
--    another week's list, which read as checking the same household again.
-- 2. A sale's label says whether it issued: "Sale - Fire · issued", "· submitted, not issued", "· partly issued".
-- 3. The cancel-word banner lists only records still open to checking.

CREATE OR REPLACE FUNCTION public.rp_spot_check_pool(p_week_end date, p_households text[] DEFAULT NULL::text[], p_checked_from date DEFAULT NULL::date, p_checked_to date DEFAULT NULL::date)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text, in_scope boolean, verified_at timestamp with time zone, entry_source text, status text, outcome text, checked_at timestamp with time zone, checked_on date, checked_by text, void_reason text)
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
           -- the kind of record the spot-check covers: self-logged, a loggable item, checkable
           (COALESCE(v.category, 'logged') = 'logged'
            AND COALESCE(v.spot_checkable, true)
            AND l.created_by IS NOT NULL
            AND l.created_by = l.team_member_id) AS checkable,
           l.verified_at, COALESCE(l.source, 'manual') AS entry_source,
           (public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk)) AS in_week,
           l.status, (l.status = 'credited') AS live,
           l.verified_by, l.voided_at, l.voided_by, l.void_reason
      FROM public.retention_activity_now l
      JOIN me ON me.agency_id = l.agency_id
      LEFT JOIN public.team_directory t ON t.id = l.team_member_id
      LEFT JOIN public.retention_point_values v
        ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
     WHERE l.status = 'credited'
        OR (l.status = 'void' AND l.void_reason LIKE 'spot-check:%')
  ),
  sale_products AS (
    SELECT sp.sales_log_id,
           min(sp.issued_date) AS issued_on,
           count(*) AS n_products,
           count(sp.issued_date) AS n_issued,
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
           'Sale - ' || COALESCE(p.lines, 'policy')
             || CASE WHEN p.n_issued = p.n_products THEN ' · issued'
                     WHEN p.n_issued = 0 THEN ' · submitted, not issued'
                     ELSE ' · partly issued' END AS label,
           COALESCE(p.issued_on, s.submitted_date) AS occurred_on,
           s.customer_label, s.customer_first_name, s.customer_last_initial,
           s.phone_last4, s.note, s.ecrm_opportunity_url AS ecrm_url,
           NULL::numeric AS points, p.premium, s.spot_check_note,
           (COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
            AND (s.created_by IS NULL OR s.created_by = s.team_member_id)) AS checkable,
           s.verified_at, COALESCE(s.entry_source, 'manual') AS entry_source,
           COALESCE(p.issued_this_week, false) AS in_week,
           s.status, (s.status = 'active') AS live,
           s.verified_by, s.voided_at, s.voided_by, s.void_reason
      FROM public.sales_log s
      JOIN sale_products p ON p.sales_log_id = s.id
      JOIN me ON me.agency_id = s.agency_id
      LEFT JOIN public.team_directory t ON t.id = s.team_member_id
     WHERE s.status = 'active'
        OR (s.status = 'void' AND s.void_reason LIKE 'spot-check:%')
  ),
  every_row AS (
    SELECT * FROM acts
    UNION ALL
    SELECT * FROM sales
  ),
  -- How a record was checked: removed by the spot-check, or verified. Neither means it has not been checked.
  -- open = still waiting to be checked. A household is open while anything in its file is.
  marked AS (
    SELECT e.*,
           (e.live AND e.checkable AND e.verified_at IS NULL) AS in_scope,
           CASE WHEN NOT e.live THEN 'removed' WHEN e.verified_at IS NOT NULL THEN 'verified' END AS outcome,
           CASE WHEN NOT e.live THEN e.voided_at ELSE e.verified_at END AS checked_at,
           CASE WHEN NOT e.live THEN e.voided_by ELSE e.verified_by END AS checker_id,
           lower(btrim(COALESCE(e.customer_label, ''))) || '|' || COALESCE(e.phone_last4, '') AS hh_key
      FROM every_row e
  ),
  keyed AS (
    SELECT m.*, bool_or(m.in_scope) OVER (PARTITION BY m.hh_key) AS hh_open
      FROM marked m
  )
  SELECT m.id, m.kind, m.team_member_id, m.first_name, m.activity_key, m.label, m.occurred_on,
         m.customer_label, m.customer_first_name, m.customer_last_initial, m.phone_last4,
         m.note, m.ecrm_url, m.points, m.premium, m.spot_check_note,
         m.in_scope, m.verified_at, m.entry_source,
         m.status, m.outcome, m.checked_at, (m.checked_at AT TIME ZONE 'America/Chicago')::date AS checked_on,
         c.first_name AS checked_by, m.void_reason
    FROM keyed m
    LEFT JOIN public.team_directory c ON c.id = m.checker_id
   WHERE public.is_agency_admin()
     AND CASE
           WHEN p_checked_from IS NOT NULL THEN
                m.outcome IS NOT NULL
            AND (m.checked_at AT TIME ZONE 'America/Chicago')::date
                BETWEEN p_checked_from AND COALESCE(p_checked_to, p_checked_from)
           -- The week's list: the week's checkable records, for every household that still has something open.
           WHEN p_households IS NULL THEN (m.live AND m.checkable AND m.in_week AND m.hh_open)
           ELSE m.live AND m.hh_key = ANY (p_households)
         END;
$function$;

-- Remaining counts what is still open in the listed households' whole files, not the week's rows.
CREATE OR REPLACE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text, in_scope boolean, verified_at timestamp with time zone, entry_source text, remaining integer, households_left integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS MATERIALIZED (SELECT * FROM public.rp_spot_check_pool(p_week_end)),
  risk AS (
    SELECT l.activity_key,
           (count(*) FILTER (WHERE l.status = 'void') + 1)::numeric / (count(*) + 8) AS w
      FROM public.retention_activity_now l
      JOIN me ON me.agency_id = l.agency_id
     GROUP BY l.activity_key
    UNION ALL
    SELECT 'sale',
           (count(*) FILTER (WHERE s.status = 'void') + 1)::numeric / (count(*) + 8)
      FROM public.sales_log s
      JOIN me ON me.agency_id = s.agency_id
     WHERE COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
  ),
  hh AS MATERIALIZED (
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
  ),
  open_left AS (
    SELECT count(*)::integer AS n FROM public.rp_spot_check_pool(
      p_week_end,
      (SELECT COALESCE(array_agg(h.key || '|' || h.ph), ARRAY[]::text[]) FROM hh h)) x
     WHERE x.in_scope
  )
  SELECT f.id, f.kind, f.team_member_id, f.first_name, f.activity_key, f.label, f.occurred_on,
         f.customer_label, f.customer_first_name, f.customer_last_initial, f.phone_last4,
         f.note, f.ecrm_url, f.points, f.premium, f.spot_check_note,
         f.in_scope, f.verified_at, f.entry_source,
         (SELECT n FROM open_left),
         (SELECT count(*) FROM hh)::integer
    FROM full_rows f
   ORDER BY lower(btrim(COALESCE(f.customer_label, ''))), COALESCE(f.phone_last4, ''),
            f.occurred_on, f.label;
$function$;

CREATE OR REPLACE FUNCTION public.rp_cancel_word_review(p_week_end date)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text, has_cancelation boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end))
  SELECT p.id, p.kind, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, p.customer_first_name, p.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points, p.premium, p.spot_check_note,
         EXISTS (
           SELECT 1 FROM public.cancelation_log c
            WHERE c.agency_id = (SELECT agency_id FROM me) AND c.status = 'active'
              AND lower(btrim(COALESCE(c.customer_label, ''))) = lower(btrim(COALESCE(p.customer_label, '')))
              AND (p.phone_last4 IS NULL OR c.phone_last4 IS NULL OR c.phone_last4 = p.phone_last4)
              AND c.canceled_on BETWEEN p.occurred_on - 21 AND p.occurred_on + 21
         )
  FROM pool p
  WHERE p.kind = 'activity'
    AND p.in_scope
    AND p.activity_key <> 'cancelation_saved'
    AND COALESCE(p.note, '') ~* '\mcancel'
  ORDER BY p.occurred_on DESC, p.first_name;
$function$;

-- Credits a sale or a cancelation wrote on its own (autopay, multiline, cancelation logged) carry the same
-- customer as their record. A name or phone fixed on the sale now moves onto them too (Daniel V. 2398).
CREATE OR REPLACE FUNCTION public.tg_rp_credits_follow_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  UPDATE public.retention_activity_log l
     SET customer_first_name = NEW.customer_first_name, customer_last_initial = NEW.customer_last_initial,
         customer_kind = NEW.customer_kind, phone_last4 = NEW.phone_last4, updated_at = now()
   WHERE l.source = TG_TABLE_NAME AND l.source_id = NEW.id
     AND (l.customer_first_name, l.customer_last_initial, l.customer_kind, l.phone_last4)
         IS DISTINCT FROM (NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind, NEW.phone_last4);
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS zz_rp_credits_follow ON public.sales_log;
CREATE TRIGGER zz_rp_credits_follow
  AFTER UPDATE OF customer_first_name, customer_last_initial, customer_kind, phone_last4 ON public.sales_log
  FOR EACH ROW EXECUTE FUNCTION public.tg_rp_credits_follow_record();
DROP TRIGGER IF EXISTS zz_rp_credits_follow ON public.cancelation_log;
CREATE TRIGGER zz_rp_credits_follow
  AFTER UPDATE OF customer_first_name, customer_last_initial, customer_kind, phone_last4 ON public.cancelation_log
  FOR EACH ROW EXECUTE FUNCTION public.tg_rp_credits_follow_record();
REVOKE ALL ON FUNCTION public.tg_rp_credits_follow_record() FROM PUBLIC, anon, authenticated;
