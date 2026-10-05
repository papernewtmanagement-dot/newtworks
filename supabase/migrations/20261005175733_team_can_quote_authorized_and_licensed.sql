CREATE OR REPLACE FUNCTION public.team_can_quote(p_team_member_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  /* Peter 2026-10-05: authorized for every license checked off, and holding a P&C or L&H
     license. Their quote of an existing customer is the pivot; everyone else logs Pivot. */
  SELECT EXISTS (SELECT 1 FROM public.team t WHERE t.id = p_team_member_id AND t.authorized
                   AND (COALESCE(t.license_pc, false) OR COALESCE(t.license_lh, false)));
$function$;
REVOKE ALL ON FUNCTION public.team_can_quote(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_can_quote(uuid) TO authenticated, service_role;
