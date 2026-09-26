-- Spot-check Checked view shows each household whole, the same file the To check list shows (Peter 2026-09-26).
-- The records checked in the day or week picked come first from rp_spot_check_pool's checked-range branch; the
-- rest of each of those households comes from its households branch, the one rp_spot_check_sample already uses.
-- Same signature and columns as before, so the screen and rp_spot_check_checked_days are untouched.
CREATE OR REPLACE FUNCTION public.rp_spot_check_checked(p_from date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(id uuid, kind text, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text, note text, ecrm_url text, points numeric, premium numeric, spot_check_note text, in_scope boolean, verified_at timestamp with time zone, entry_source text, status text, outcome text, checked_at timestamp with time zone, checked_on date, checked_by text, void_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
SELECT public.require_login('staff');
  WITH hit AS MATERIALIZED (
    SELECT * FROM public.rp_spot_check_pool(NULL, NULL, p_from, COALESCE(p_to, p_from))
  ),
  hh AS MATERIALIZED (
    SELECT lower(btrim(COALESCE(h.customer_label, ''))) || '|' || COALESCE(h.phone_last4, '') AS key,
           min(h.checked_at) AS first_checked
      FROM hit h
     GROUP BY 1
  ),
  -- Everything else those households have on file: other weeks, backfill, records checked on another day,
  -- and anything still open to checking.
  rest AS MATERIALIZED (
    SELECT f.*
      FROM public.rp_spot_check_pool(NULL, (SELECT COALESCE(array_agg(hh.key), ARRAY[]::text[]) FROM hh)) f
     WHERE NOT EXISTS (SELECT 1 FROM hit h WHERE h.id = f.id AND h.kind = f.kind)
  ),
  every_row AS MATERIALIZED (
    SELECT * FROM hit
    UNION ALL
    SELECT * FROM rest
  )
  -- Households in the order they were first checked, each one's records by date.
  SELECT e.*
    FROM every_row e
    JOIN hh ON hh.key = lower(btrim(COALESCE(e.customer_label, ''))) || '|' || COALESCE(e.phone_last4, '')
   ORDER BY hh.first_checked, hh.key, e.occurred_on, e.checked_at NULLS LAST, e.label;
$function$;
