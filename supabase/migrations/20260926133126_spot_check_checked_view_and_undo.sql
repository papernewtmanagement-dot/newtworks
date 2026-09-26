-- Spot-check gets a Checked view (Peter 2026-09-26). A toggle on the Spot-check tab swaps the records still to check
-- for the ones already checked, a day or a week at a time, with the same buttons and an Undo.
-- rp_spot_check_pool stays the ONE place a spot-check row is built. It gains a third mode:
--   A. no households, no dates: the week's records still open to checking (unchanged)
--   B. households given: those households' whole live file, all weeks (unchanged)
--   C. p_checked_from given: every record checked on those Central days, verified or removed by the spot-check
-- Every row now also carries its status, how it was checked (outcome verified or removed), when (checked_at, and the
-- Central day as checked_on), by whom (checked_by, a first name) and the void reason. A record removed by the
-- spot-check (void_reason 'spot-check: ...') only ever comes back in mode C.
-- Readers: rp_spot_check_checked(from, to) is mode C for the tab, rp_spot_check_checked_days(days) lists the days
-- that have checks, rp_spot_check_undo(kind, id) takes a check back.
-- The pool stays internal (no grant to authenticated), same as before; its two callers keep their one-date form.

DROP FUNCTION public.rp_spot_check_pool(date, text[]);

CREATE FUNCTION public.rp_spot_check_pool(p_week_end date, p_households text[] DEFAULT NULL::text[],
                                          p_checked_from date DEFAULT NULL::date, p_checked_to date DEFAULT NULL::date)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
               occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
               phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text,
               in_scope boolean, verified_at timestamp with time zone, entry_source text,
               status text, outcome text, checked_at timestamp with time zone, checked_on date, checked_by text,
               void_reason text)
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
           (l.status = 'credited'
            AND l.verified_at IS NULL
            AND COALESCE(v.category, 'logged') = 'logged'
            AND COALESCE(v.spot_checkable, true)
            AND l.created_by IS NOT NULL
            AND l.created_by = l.team_member_id) AS in_scope,
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
           (s.status = 'active'
            AND s.verified_at IS NULL
            AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
            AND (s.created_by IS NULL OR s.created_by = s.team_member_id)) AS in_scope,
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
  marked AS (
    SELECT e.*,
           CASE WHEN NOT e.live THEN 'removed' WHEN e.verified_at IS NOT NULL THEN 'verified' END AS outcome,
           CASE WHEN NOT e.live THEN e.voided_at ELSE e.verified_at END AS checked_at,
           CASE WHEN NOT e.live THEN e.voided_by ELSE e.verified_by END AS checker_id
      FROM every_row e
  )
  SELECT m.id, m.kind, m.team_member_id, m.first_name, m.activity_key, m.label, m.occurred_on,
         m.customer_label, m.customer_first_name, m.customer_last_initial, m.phone_last4,
         m.note, m.ecrm_url, m.points, m.premium, m.spot_check_note,
         m.in_scope, m.verified_at, m.entry_source,
         m.status, m.outcome, m.checked_at, (m.checked_at AT TIME ZONE 'America/Chicago')::date AS checked_on,
         c.first_name AS checked_by, m.void_reason
    FROM marked m
    LEFT JOIN public.team_directory c ON c.id = m.checker_id
   WHERE public.is_agency_admin()
     AND CASE
           WHEN p_checked_from IS NOT NULL THEN
                m.outcome IS NOT NULL
            AND (m.checked_at AT TIME ZONE 'America/Chicago')::date
                BETWEEN p_checked_from AND COALESCE(p_checked_to, p_checked_from)
           WHEN p_households IS NULL THEN (m.live AND m.in_scope AND m.in_week)
           ELSE m.live
            AND (lower(btrim(COALESCE(m.customer_label, ''))) || '|' || COALESCE(m.phone_last4, ''))
                = ANY (p_households)
         END;
$function$;

REVOKE ALL ON FUNCTION public.rp_spot_check_pool(date, text[], date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rp_spot_check_pool(date, text[], date, date) TO service_role;

-- The Checked view: everything checked from p_from to p_to (Central days), a household at a time in the order
-- they were first checked, each household's records by date.
CREATE OR REPLACE FUNCTION public.rp_spot_check_checked(p_from date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
               occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
               phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text,
               in_scope boolean, verified_at timestamp with time zone, entry_source text,
               status text, outcome text, checked_at timestamp with time zone, checked_on date, checked_by text,
               void_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  SELECT p.*
    FROM public.rp_spot_check_pool(NULL, NULL, p_from, COALESCE(p_to, p_from)) p
   ORDER BY min(p.checked_at) OVER (PARTITION BY lower(btrim(COALESCE(p.customer_label, ''))), COALESCE(p.phone_last4, '')),
            lower(btrim(COALESCE(p.customer_label, ''))), COALESCE(p.phone_last4, ''),
            p.occurred_on, p.checked_at, p.label;
$function$;

-- The Checked view's picker: each Central day with checks on it in the last p_days, newest first, with its week
-- (Sunday to Saturday, rp_week_end) and how many records were verified and removed.
CREATE OR REPLACE FUNCTION public.rp_spot_check_checked_days(p_days integer DEFAULT 90)
 RETURNS TABLE(checked_on date, week_end date, verified integer, removed integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  SELECT p.checked_on, public.rp_week_end(p.checked_on) AS week_end,
         count(*) FILTER (WHERE p.outcome = 'verified')::integer AS verified,
         count(*) FILTER (WHERE p.outcome = 'removed')::integer AS removed
    FROM public.rp_spot_check_pool(
           NULL, NULL,
           (now() AT TIME ZONE 'America/Chicago')::date - GREATEST(1, LEAST(COALESCE(p_days, 90), 366)),
           (now() AT TIME ZONE 'America/Chicago')::date) p
   GROUP BY p.checked_on
   ORDER BY p.checked_on DESC;
$function$;

-- Undo a check. A verified record goes back to unverified, so it is on the list to check again; its spot-check note
-- stays. A record the spot-check removed comes back exactly the way the History tab's Restore brings it back
-- (rp_restore_record: the entry, and for a sale the credits it wrote). Admins only, like Verified and Remove.
CREATE OR REPLACE FUNCTION public.rp_spot_check_undo(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_status text; v_reason text; v_verified timestamptz;
BEGIN
  PERFORM public.require_login('staff');
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can undo a spot-check' USING ERRCODE='42501'; END IF;
  IF p_kind = 'activity' THEN
    SELECT l.status, l.void_reason, l.verified_at INTO v_status, v_reason, v_verified
      FROM public.retention_activity_log l WHERE l.id = p_id AND l.agency_id = a.agency_id;
  ELSIF p_kind = 'sale' THEN
    SELECT s.status, s.void_reason, s.verified_at INTO v_status, v_reason, v_verified
      FROM public.sales_log s WHERE s.id = p_id AND s.agency_id = a.agency_id;
  ELSE
    RAISE EXCEPTION 'cannot undo a spot-check on a record of kind %', p_kind;
  END IF;
  IF v_status IS NULL THEN RAISE EXCEPTION 'that record is not on file any more'; END IF;

  IF v_status = 'void' THEN
    IF COALESCE(v_reason, '') NOT LIKE 'spot-check:%' THEN
      RAISE EXCEPTION 'that record was removed some other way, not by the spot-check';
    END IF;
    RETURN public.rp_restore_record(p_kind, p_id) || jsonb_build_object('undone', 'removed');
  END IF;

  IF v_verified IS NULL THEN RAISE EXCEPTION 'nothing to undo: that record has not been checked'; END IF;
  IF p_kind = 'activity' THEN
    UPDATE public.retention_activity_log SET verified_at = NULL, verified_by = NULL, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSE
    UPDATE public.sales_log SET verified_at = NULL, verified_by = NULL, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'undone', 'verified');
END $function$;

REVOKE ALL ON FUNCTION public.rp_spot_check_checked(date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rp_spot_check_checked_days(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rp_spot_check_undo(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_spot_check_checked(date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rp_spot_check_checked_days(integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rp_spot_check_undo(text, uuid) TO authenticated, service_role;

-- Guards: the pool has exactly one form and stays internal; the three readers are open to signed-in people only.
DO $guard$
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'rp_spot_check_pool') <> 1 THEN
    RAISE EXCEPTION 'rp_spot_check_pool must have exactly one form';
  END IF;
  IF has_function_privilege('authenticated', 'public.rp_spot_check_pool(date, text[], date, date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rp_spot_check_pool(date, text[], date, date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rp_spot_check_pool must stay internal';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rp_spot_check_checked(date, date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rp_spot_check_checked_days(integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rp_spot_check_undo(text, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the Checked view readers must be open to signed-in people';
  END IF;
  IF has_function_privilege('anon', 'public.rp_spot_check_checked(date, date)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rp_spot_check_checked_days(integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rp_spot_check_undo(text, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the Checked view readers must not be open to anon';
  END IF;
END
$guard$;
