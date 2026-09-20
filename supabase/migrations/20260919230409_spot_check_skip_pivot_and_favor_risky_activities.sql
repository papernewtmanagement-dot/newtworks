-- Peter 2026-09-19:
--
-- 1. A Pivot cannot be verified from anything on the record, so checking one
--    is wasted effort. It drops out of the spot-check pool entirely. Which
--    activities are checkable is a flag on the activity, the same as the note,
--    ECRM and review-site requirements, so turning another one off later is a
--    setting rather than a code change.
--
-- 2. The ten households are no longer drawn flat. Activities that get changed
--    when they are checked are the ones worth checking, so a household holding
--    one of those is likelier to come up.
--
--    The weight per activity is its correction rate, (corrected + 1) over
--    (logged + 8). The +1 and +8 are a prior: without them a single correction
--    on a single entry would read as a 100% failure rate and swamp everything.
--    Right now that puts Policy Change near 0.39 and most others near 0.06.
--
--    The draw itself is Efraimidis and Spirakis weighted sampling without
--    replacement: score each household u^(1/weight) and take the highest.
--    A heavier household is likelier, never certain, so nothing gets a
--    permanent free pass. u is the same seeded hash as before, so the same ten
--    still come back all week until they are cleared.

ALTER TABLE public.retention_point_values
  ADD COLUMN IF NOT EXISTS spot_checkable boolean NOT NULL DEFAULT true;

UPDATE public.retention_point_values
   SET spot_checkable = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND activity_key = 'pivot';

CREATE OR REPLACE FUNCTION public.rp_spot_check_pool(p_week_end date)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, phone_last4 text, note text,
              ecrm_url text, points numeric)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  wk AS (SELECT public.rp_week_end(p_week_end) AS week_end)
  SELECT l.id, l.team_member_id, t.first_name, l.activity_key, v.label, l.occurred_on,
         l.customer_label, l.phone_last4,
         CASE WHEN l.review_platform IS NULL THEN l.note
              ELSE initcap(l.review_platform) || COALESCE(' — ' || l.note, '') END,
         l.ecrm_url, l.points
  FROM public.retention_activity_log l
  JOIN me ON me.agency_id = l.agency_id
  LEFT JOIN public.team_directory t ON t.id = l.team_member_id
  LEFT JOIN public.retention_point_values v
    ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited'
    AND l.verified_at IS NULL
    AND l.created_by IS NOT NULL
    AND l.created_by = l.team_member_id
    AND COALESCE(v.spot_checkable, true)
    AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk);
$function$;

REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM anon, authenticated;

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
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end)),
  risk AS (
    SELECT l.activity_key,
           (count(*) FILTER (WHERE l.status = 'void') + 1)::numeric / (count(*) + 8) AS w
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
     WHERE l.source = 'manual'
     GROUP BY l.activity_key
  ),
  hh AS (
    SELECT p.customer_label, COALESCE(p.phone_last4, '') AS ph,
           max(COALESCE(r.w, 1.0 / 9)) AS w
      FROM pool p LEFT JOIN risk r ON r.activity_key = p.activity_key
     GROUP BY 1, 2
  ),
  picked AS (
    SELECT h.customer_label, h.ph FROM hh h
     ORDER BY power(
       ((('x' || substr(md5(COALESCE(h.customer_label, '') || h.ph
                            || public.rp_week_end(p_week_end)::text), 1, 8))::bit(32)::int::numeric
         + 2147483648) / 4294967296.0),
       1.0 / GREATEST(h.w, 0.01)) DESC
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
