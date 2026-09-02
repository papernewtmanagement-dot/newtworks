-- Log-for is OWNER only.
--
-- rp_resolve_actor decided who an entry belongs to. It let anyone who passed
-- is_agency_admin() log on another person's behalf, and that check is true for
-- managers as well as the owner. Peter's rule is owner only: a manager logs for
-- themselves like everyone else. This closes the gap on the server so hiding the
-- picker in the page is not the only thing stopping it.
--
-- is_admin is still returned, unchanged, and still means owner-or-manager. The
-- void functions (rp_void_activity / rp_void_quote / rp_void_sale /
-- rp_void_cancellation) use it to let a manager remove another person's entry or
-- an entry older than seven days. That is a separate rule and is left alone.

CREATE OR REPLACE FUNCTION public.rp_resolve_actor(p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(actor_id uuid, team_member_id uuid, agency_id uuid, is_admin boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_actor uuid; v_agency uuid; v_admin boolean; v_owner boolean; v_target uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated' USING ERRCODE='42501'; END IF;
  SELECT t.id, t.agency_id INTO v_actor, v_agency
  FROM public.team t JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = v_uid AND t.archived_at IS NULL
  LIMIT 1;
  v_admin := public.is_agency_admin();
  v_owner := COALESCE(public.current_app_user_role() = 'owner', false);
  IF v_actor IS NULL AND NOT v_admin THEN
    RAISE EXCEPTION 'no active team member for authenticated user' USING ERRCODE='42501';
  END IF;
  IF v_agency IS NULL THEN
    SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = v_uid LIMIT 1;
  END IF;
  -- Only the owner may log on behalf of anyone else. Everyone else, managers
  -- included, logs only for themselves.
  IF p_team_member_id IS NOT NULL AND p_team_member_id <> COALESCE(v_actor, '00000000-0000-0000-0000-000000000000'::uuid) THEN
    IF NOT v_owner THEN RAISE EXCEPTION 'only the owner can log for someone else' USING ERRCODE='42501'; END IF;
    v_target := p_team_member_id;
  ELSE
    v_target := v_actor;
  END IF;
  IF v_target IS NULL THEN RAISE EXCEPTION 'pick a team member' USING ERRCODE='22023'; END IF;
  RETURN QUERY SELECT v_actor, v_target, v_agency, v_admin;
END $function$;

COMMENT ON FUNCTION public.rp_resolve_actor(uuid) IS
  'Resolves who a Retention Points entry belongs to. Logging on another person''s behalf is owner only (users.role = owner); managers log for themselves. The returned is_admin still means owner-or-manager and is what the void functions use.';
