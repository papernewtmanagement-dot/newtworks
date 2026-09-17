-- Peter 2026-09-16: the spot-check was pulling in the historical records he
-- seeded himself and the ones he logged on someone else's behalf. Those are
-- not self-reports, so there is nothing to check against. Core principle 450
-- puts the monthly spot-check on SELF-LOGGED entries only: the person who
-- earned the points is the person who typed them in.
--   created_by IS NULL            -> backfilled/seeded, not typed by anyone
--   created_by <> team_member_id  -> logged for someone else (owner only)
-- Both now fall out of the pool.
CREATE OR REPLACE FUNCTION public.rp_spot_check_sample(p_month date, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, note text, ecrm_url text, points numeric, remaining integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (
    SELECT l.id, l.team_member_id, l.activity_key, l.occurred_on, l.customer_label, l.note, l.ecrm_url, l.points
    FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id
    WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited' AND l.verified_at IS NULL
      AND l.created_by IS NOT NULL
      AND l.created_by = l.team_member_id
      AND l.occurred_on >= date_trunc('month', p_month)::date
      AND l.occurred_on <  (date_trunc('month', p_month) + interval '1 month')::date
  )
  SELECT p.id, p.team_member_id, t.first_name, p.activity_key, v.label, p.occurred_on,
         p.customer_label, p.note, p.ecrm_url, p.points, (SELECT count(*) FROM pool)::integer
  FROM pool p
  LEFT JOIN public.team_directory t ON t.id = p.team_member_id
  LEFT JOIN public.retention_point_values v ON v.activity_key = p.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  ORDER BY md5(p.id::text || date_trunc('month', p_month)::date::text)
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));
$function$;
