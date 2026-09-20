-- Spot-check pool now covers everything a person typed in, not just the
-- retention activity log. Two defects fixed together:
--   1. The pool filtered on source = 'manual'. Autopay Enrollment is typed by
--      the person on the sale screen, so its point row carries source
--      'sales_log' and was silently skipped even though it pays 2.50 and is
--      marked spot-checkable. The real test is the point value's category:
--      'logged' means somebody typed it, 'derived' and 'system' mean the
--      database worked it out and there is nothing to check.
--   2. Sales themselves were never in the pool. 14 sales issued in the week
--      ending 2026-09-19 and not one could be checked. A sale is the biggest
--      thing anyone types in: customer, ECRM link, lines, premium, marketing
--      source. It belongs in the sample.
-- Households are keyed the same way for both, customer label plus the last
-- four of the phone, so a sale and the activities on the same customer land
-- on the same card.

ALTER TABLE public.sales_log
  ADD COLUMN IF NOT EXISTS verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS verified_by uuid,
  ADD COLUMN IF NOT EXISTS spot_check_note text;

-- One unverify rule for every record kind. The body never names a table, so
-- the same function serves the activity log and the sales log. An admin
-- editing a verified record leaves it verified; anyone else editing it sends
-- it back to be checked again.
CREATE OR REPLACE FUNCTION public.rp_unverify_on_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE skip text[] := ARRAY['verified_at', 'verified_by', 'updated_at', 'spot_check_note'];
BEGIN
  IF NEW.verified_at IS NULL THEN RETURN NEW; END IF;
  IF public.is_agency_admin() THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - skip) IS DISTINCT FROM (to_jsonb(OLD) - skip) THEN
    NEW.verified_at := NULL;
    NEW.verified_by := NULL;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS retention_activity_unverify_on_change ON public.retention_activity_log;
DROP FUNCTION IF EXISTS public.retention_activity_unverify_on_change();

DROP TRIGGER IF EXISTS rp_unverify_on_change ON public.retention_activity_log;
CREATE TRIGGER rp_unverify_on_change
  BEFORE UPDATE ON public.retention_activity_log
  FOR EACH ROW EXECUTE FUNCTION public.rp_unverify_on_change();

DROP TRIGGER IF EXISTS rp_unverify_on_change ON public.sales_log;
CREATE TRIGGER rp_unverify_on_change
  BEFORE UPDATE ON public.sales_log
  FOR EACH ROW EXECUTE FUNCTION public.rp_unverify_on_change();

DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);
DROP FUNCTION IF EXISTS public.rp_cancel_word_review(date);
DROP FUNCTION IF EXISTS public.rp_spot_check_pool(date);

CREATE FUNCTION public.rp_spot_check_pool(p_week_end date)
RETURNS TABLE(
  id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
  occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
  phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text)
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
           l.ecrm_url, l.points, NULL::numeric AS premium, l.spot_check_note
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
      LEFT JOIN public.team_directory t ON t.id = l.team_member_id
      LEFT JOIN public.retention_point_values v
        ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
     WHERE l.status = 'credited'
       AND COALESCE(v.category, 'logged') = 'logged'
       AND l.verified_at IS NULL
       AND l.created_by IS NOT NULL
       AND l.created_by = l.team_member_id
       AND COALESCE(v.spot_checkable, true)
       AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk)
  ),
  sale_products AS (
    SELECT sp.sales_log_id,
           min(sp.issued_date) AS issued_on,
           sum(COALESCE(sp.issued_premium, sp.premium, 0)) AS premium,
           string_agg(DISTINCT initcap(sp.line_of_business), ', ') AS lines
      FROM public.sales_log_products sp
      JOIN me ON me.agency_id = sp.agency_id
     WHERE sp.issued_date IS NOT NULL
       AND public.rp_week_end(sp.issued_date) = (SELECT week_end FROM wk)
     GROUP BY sp.sales_log_id
  ),
  sales AS (
    SELECT s.id, 'sale'::text AS kind, s.team_member_id, t.first_name, 'sale'::text AS activity_key,
           'Sale - ' || COALESCE(p.lines, 'policy') AS label,
           p.issued_on AS occurred_on, s.customer_label, s.customer_first_name, s.customer_last_initial,
           s.phone_last4, s.note, s.ecrm_opportunity_url AS ecrm_url,
           NULL::numeric AS points, p.premium, s.spot_check_note
      FROM public.sales_log s
      JOIN sale_products p ON p.sales_log_id = s.id
      JOIN me ON me.agency_id = s.agency_id
      LEFT JOIN public.team_directory t ON t.id = s.team_member_id
     WHERE s.status = 'active'
       AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
       AND s.verified_at IS NULL
       AND (s.created_by IS NULL OR s.created_by = s.team_member_id)
  )
  SELECT * FROM acts WHERE public.is_agency_admin()
  UNION ALL
  SELECT * FROM sales WHERE public.is_agency_admin();
$function$;

CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(
  id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
  occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
  phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text,
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
  )
  SELECT p.id, p.kind, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, p.customer_first_name, p.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points, p.premium, p.spot_check_note,
         (SELECT count(*) FROM pool)::integer,
         (SELECT count(*) FROM hh)::integer
    FROM pool p
    JOIN picked k ON k.key = lower(btrim(COALESCE(p.customer_label, '')))
                 AND k.ph = COALESCE(p.phone_last4, '')
   ORDER BY lower(btrim(COALESCE(p.customer_label, ''))), p.occurred_on, p.label;
$function$;

CREATE FUNCTION public.rp_cancel_word_review(p_week_end date)
RETURNS TABLE(
  id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text,
  occurred_on date, customer_label text, customer_first_name text, customer_last_initial text,
  phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text,
  has_cancelation boolean)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
    AND p.activity_key <> 'cancelation_saved'
    AND COALESCE(p.note, '') ~* '\mcancel'
  ORDER BY p.occurred_on DESC, p.first_name;
$function$;

CREATE OR REPLACE FUNCTION public.rp_spot_check_weeks(p_weeks integer DEFAULT 12)
RETURNS TABLE(week_end date, entries integer, unverified integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  acts AS (
    SELECT public.rp_week_end(l.occurred_on) AS week_end, l.verified_at
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
      LEFT JOIN public.retention_point_values v
        ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
     WHERE l.status = 'credited'
       AND COALESCE(v.category, 'logged') = 'logged'
       AND COALESCE(v.spot_checkable, true)
       AND l.created_by IS NOT NULL
       AND l.created_by = l.team_member_id
  ),
  sale_weeks AS (
    SELECT DISTINCT public.rp_week_end(sp.issued_date) AS week_end, s.id, s.verified_at
      FROM public.sales_log_products sp
      JOIN public.sales_log s ON s.id = sp.sales_log_id
      JOIN me ON me.agency_id = s.agency_id
     WHERE sp.issued_date IS NOT NULL
       AND s.status = 'active'
       AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
       AND (s.created_by IS NULL OR s.created_by = s.team_member_id)
  ),
  every_row AS (
    SELECT week_end, verified_at FROM acts
    UNION ALL
    SELECT week_end, verified_at FROM sale_weeks
  )
  SELECT e.week_end,
         count(*)::integer AS entries,
         count(*) FILTER (WHERE e.verified_at IS NULL)::integer AS unverified
  FROM every_row e
  WHERE public.is_agency_admin()
  GROUP BY 1
  ORDER BY 1 DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_weeks, 12), 52));
$function$;
