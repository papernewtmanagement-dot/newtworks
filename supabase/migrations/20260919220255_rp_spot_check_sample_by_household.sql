-- Peter 2026-09-19: the spot-check picks households, not entries, and shows
-- every entry for each one together.
--
-- Padding is a household pattern, not a single-entry one. Three Policy Changes
-- on one customer in a week is the thing worth catching, and picking ten
-- entries scattered that across the pool so at most one of the three was ever
-- looked at. Ten households shows the whole interaction in one place.
--
-- The draw is still fixed for the week: the same households come back until
-- they are cleared, because the order is seeded on the household and the week.
--
-- remaining still counts entries, as it always did. households_left is the new
-- one, and it is what the screen counts down.

DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);

CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, customer_first_name text,
              customer_last_initial text, phone_last4 text, note text, ecrm_url text,
              points numeric, remaining integer, households_left integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end)),
  hh AS (
    SELECT p.customer_label, COALESCE(p.phone_last4, '') AS ph
      FROM pool p GROUP BY 1, 2
  ),
  picked AS (
    SELECT h.customer_label, h.ph FROM hh h
     ORDER BY md5(COALESCE(h.customer_label, '') || h.ph || public.rp_week_end(p_week_end)::text)
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50))
  )
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, l.customer_first_name, l.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points,
         (SELECT count(*) FROM pool)::integer,
         (SELECT count(*) FROM hh)::integer
    FROM pool p
    JOIN picked k ON COALESCE(k.customer_label, '') = COALESCE(p.customer_label, '')
                 AND k.ph = COALESCE(p.phone_last4, '')
    JOIN public.retention_activity_log l ON l.id = p.id
   ORDER BY p.customer_label, p.occurred_on, p.label;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;
