-- Monthly spot-check (core principle 450: self-logged entries get a monthly
-- spot-check). A stable random sample of up to ten self-logged, still-credited,
-- not-yet-verified rows from a month. Stable: the same month gives the same
-- ten until they are verified, so a refresh never shuffles the list. Owner
-- and manager only, same as the other admin views.
CREATE OR REPLACE FUNCTION public.rp_spot_check_sample(p_month date, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text, occurred_on date,
               customer_label text, note text, ecrm_url text, points numeric, remaining integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (
    SELECT l.id, l.team_member_id, l.activity_key, l.occurred_on, l.customer_label, l.note, l.ecrm_url, l.points
    FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id
    WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited' AND l.verified_at IS NULL
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
REVOKE ALL ON FUNCTION public.rp_spot_check_sample(date, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.rp_verify_activity(p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can verify entries' USING ERRCODE='42501'; END IF;
  UPDATE public.retention_activity_log
     SET verified_at = now(), verified_by = a.actor_id, updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id AND status = 'credited' AND verified_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'nothing to verify: entry not found, already verified, or removed'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;
REVOKE ALL ON FUNCTION public.rp_verify_activity(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_verify_activity(uuid) TO authenticated;
