-- Peter 2026-09-19: a note that says "cancel" on an entry logged as something
-- else needs to reach him, not be blocked automatically. It might be an
-- honest policy change where the word just came up, or it might be a
-- cancelation that was never logged as one. He decides.
--
-- The random ten cannot be the only way he sees these, or one lands in the
-- sample about a third of the time and the rest are never looked at. So the
-- flagged entries come back on their own, for the whole week.
--
-- The pool the spot-check draws from moves into its own function so the
-- sample and this review read the same rows. Only self-logged, still
-- credited, not yet verified.

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
         l.customer_label, l.phone_last4, l.note, l.ecrm_url, l.points
  FROM public.retention_activity_log l
  JOIN me ON me.agency_id = l.agency_id
  LEFT JOIN public.team_directory t ON t.id = l.team_member_id
  LEFT JOIN public.retention_point_values v
    ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited'
    AND l.verified_at IS NULL
    AND l.created_by IS NOT NULL
    AND l.created_by = l.team_member_id
    AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk);
$function$;

REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, note text, ecrm_url text,
              points numeric, remaining integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end))
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, p.note, p.ecrm_url, p.points, (SELECT count(*) FROM pool)::integer
  FROM pool p
  ORDER BY md5(p.id::text || public.rp_week_end(p_week_end)::text)
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50));
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;

-- Entries whose note mentions cancel but that were not logged as a
-- Cancelation Saved. has_cancelation says whether a cancelation is already on
-- file for that household within three weeks either side, which is usually
-- what settles whether it was a policy change or a cancelation.
CREATE OR REPLACE FUNCTION public.rp_cancel_word_review(p_week_end date)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, phone_last4 text, note text,
              ecrm_url text, points numeric, has_cancelation boolean)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end))
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, p.phone_last4, p.note, p.ecrm_url, p.points,
         EXISTS (
           SELECT 1 FROM public.cancelation_log c
            WHERE c.agency_id = (SELECT agency_id FROM me)
              AND c.status = 'active'
              AND lower(btrim(COALESCE(c.customer_label, ''))) = lower(btrim(COALESCE(p.customer_label, '')))
              AND (p.phone_last4 IS NULL OR c.phone_last4 IS NULL OR c.phone_last4 = p.phone_last4)
              AND c.canceled_on BETWEEN p.occurred_on - 21 AND p.occurred_on + 21
         ) AS has_cancelation
  FROM pool p
  WHERE p.activity_key <> 'cancelation_saved'
    AND COALESCE(p.note, '') ~* '\mcancel'
  ORDER BY p.occurred_on DESC, p.first_name;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_cancel_word_review(date) TO authenticated;
