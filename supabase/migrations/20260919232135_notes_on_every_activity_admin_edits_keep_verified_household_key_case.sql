-- Peter 2026-09-19, three fixes off one spot-check session.
--
-- 1. A note is required on every logged activity. Only Cancelation Saved and
--    Policy Review asked for one, which is how a Walk-In Helped got on file
--    with nothing written on it and nothing to check it against.
--
-- 2. Correcting an entry while checking it should not throw away the check he
--    just did. Only a change by someone other than an admin puts an entry back
--    in the pool — which is the case the flag is for: the team changing
--    something after it was approved. An admin correcting it is the check.
--
-- 3. The household key was case-sensitive, so "Deborah C." and "DEBORAH C."
--    counted as two households and their entries were drawn separately.

UPDATE public.retention_point_values
   SET requires_note = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND category = 'logged';

CREATE OR REPLACE FUNCTION public.retention_activity_unverify_on_change()
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
CREATE TRIGGER retention_activity_unverify_on_change
BEFORE UPDATE ON public.retention_activity_log
FOR EACH ROW EXECUTE FUNCTION public.retention_activity_unverify_on_change();

-- The household key ignores case now, here and in the draw.
DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);

CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, customer_first_name text,
              customer_last_initial text, phone_last4 text, note text, ecrm_url text,
              points numeric, spot_check_note text, remaining integer, households_left integer)
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
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, l.customer_first_name, l.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points, p.spot_check_note,
         (SELECT count(*) FROM pool)::integer,
         (SELECT count(*) FROM hh)::integer
    FROM pool p
    JOIN picked k ON k.key = lower(btrim(COALESCE(p.customer_label, '')))
                 AND k.ph = COALESCE(p.phone_last4, '')
    JOIN public.retention_activity_log l ON l.id = p.id
   ORDER BY lower(btrim(COALESCE(p.customer_label, ''))), p.occurred_on, p.label;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;
