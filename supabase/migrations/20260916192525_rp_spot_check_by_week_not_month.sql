-- Peter 2026-09-16: the spot-check runs by week, not by month, and opens on
-- the current week unless the current week has nothing in it. Sunday through
-- Saturday, same week boundary as everything else, via rp_week_end().
--
-- Pool rule unchanged from earlier today: SELF-LOGGED entries only, meaning
-- the person who earned the points is the person who typed them in.
--   created_by IS NULL            -> backfilled/seeded, nobody typed it
--   created_by <> team_member_id  -> logged for someone else (owner only)
-- Both stay out, so the historical records Peter seeded are never checked back.

-- Which weeks the picker offers, newest first. A week appears if anyone
-- self-logged in it, even once it is fully cleared, so the week you are
-- looking at does not vanish out of the dropdown as you verify it.
CREATE OR REPLACE FUNCTION public.rp_spot_check_weeks(p_weeks integer DEFAULT 12)
 RETURNS TABLE(week_end date, entries integer, unverified integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT public.rp_week_end(l.occurred_on) AS week_end,
         count(*)::integer AS entries,
         count(*) FILTER (WHERE l.verified_at IS NULL)::integer AS unverified
  FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id
  WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited'
    AND l.created_by IS NOT NULL AND l.created_by = l.team_member_id
  GROUP BY 1
  ORDER BY 1 DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_weeks, 12), 52));
$function$;

-- Signature changes from p_month to p_week_end, so the old one goes first.
-- Only caller is src/modules/ActivityLog.jsx (SpotCheck), updated same commit.
DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);

CREATE OR REPLACE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date, customer_label text, note text, ecrm_url text, points numeric, remaining integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  wk AS (SELECT public.rp_week_end(p_week_end) AS week_end),
  pool AS (
    SELECT l.id, l.team_member_id, l.activity_key, l.occurred_on, l.customer_label, l.note, l.ecrm_url, l.points
    FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id
    WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited' AND l.verified_at IS NULL
      AND l.created_by IS NOT NULL
      AND l.created_by = l.team_member_id
      AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk)
  )
  SELECT p.id, p.team_member_id, t.first_name, p.activity_key, v.label, p.occurred_on,
         p.customer_label, p.note, p.ecrm_url, p.points, (SELECT count(*) FROM pool)::integer
  FROM pool p
  LEFT JOIN public.team_directory t ON t.id = p.team_member_id
  LEFT JOIN public.retention_point_values v ON v.activity_key = p.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  ORDER BY md5(p.id::text || (SELECT week_end FROM wk)::text)
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));
$function$;
