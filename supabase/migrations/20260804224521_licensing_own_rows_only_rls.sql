-- Licensing — own-rows-only access enforced in the database, not just the screen.
-- Before: team_licenses read rule was "allow everyone" for signed-out and signed-in
-- alike, so every licence row was pullable with the public browser key; the
-- per-person view existed only as a browser-side filter. Writes were equally wide.
-- After: owner+manager full access; everyone else read+change own rows only,
-- no add, no delete; signed-out nothing.

CREATE OR REPLACE FUNCTION public.current_app_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.role
  FROM public.users u
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.current_app_user_role() IS
  'Role of the signed-in person from public.users. NULL when nobody is signed in or no matching users row exists. Joins on users.auth_user_id, never on users.id.';

CREATE OR REPLACE FUNCTION public.is_agency_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(public.current_app_user_role() IN ('owner', 'manager'), false);
$$;

COMMENT ON FUNCTION public.is_agency_admin() IS
  'True when the signed-in person is owner or manager. False for everyone else and for signed-out requests. Matches the ADMIN_ROLES list in NewtworksApp.jsx.';

CREATE OR REPLACE FUNCTION public.current_team_member_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT t.id
  FROM public.team t
  JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = auth.uid()
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.current_team_member_id() IS
  'The public.team row id belonging to the signed-in person, via team.user_id -> users.id -> users.auth_user_id. NULL when unlinked or signed out, so ownership tests fail closed.';

GRANT EXECUTE ON FUNCTION public.current_app_user_role()  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_agency_admin()        TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_team_member_id() TO anon, authenticated, service_role;

DROP POLICY IF EXISTS anon_read_team_licenses            ON public.team_licenses;
DROP POLICY IF EXISTS authenticated_insert_team_licenses ON public.team_licenses;
DROP POLICY IF EXISTS authenticated_update_team_licenses ON public.team_licenses;
DROP POLICY IF EXISTS authenticated_delete_team_licenses ON public.team_licenses;

CREATE POLICY licenses_select_admin_or_own ON public.team_licenses
  FOR SELECT TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND (public.is_agency_admin() OR team_member_id = public.current_team_member_id())
  );

CREATE POLICY licenses_insert_admin_only ON public.team_licenses
  FOR INSERT TO authenticated
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND public.is_agency_admin()
  );

CREATE POLICY licenses_update_admin_or_own ON public.team_licenses
  FOR UPDATE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND (public.is_agency_admin() OR team_member_id = public.current_team_member_id())
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND (public.is_agency_admin() OR team_member_id = public.current_team_member_id())
  );

CREATE POLICY licenses_delete_admin_only ON public.team_licenses
  FOR DELETE TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND public.is_agency_admin()
  );

CREATE OR REPLACE FUNCTION public.mark_license_complete(p_license_id uuid, p_completed_on date DEFAULT CURRENT_DATE)
 RETURNS team_licenses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.team_licenses;
  v_next_due date;
BEGIN
  SELECT * INTO v_row FROM public.team_licenses WHERE id = p_license_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'license not found: %', p_license_id;
  END IF;

  -- Authorisation must live here: this function runs with owner rights and so
  -- the row rules on team_licenses do not apply to it.
  IF NOT (
       coalesce(auth.role(), '') = 'service_role'
       OR public.is_agency_admin()
       OR v_row.team_member_id = public.current_team_member_id()
     ) THEN
    RAISE EXCEPTION 'not authorized to mark this license complete';
  END IF;

  IF v_row.cycle_months IS NULL THEN
    UPDATE public.team_licenses
    SET status = 'complete_onetime',
        last_completed_at = p_completed_on
    WHERE id = p_license_id
    RETURNING * INTO v_row;

    UPDATE public.alerts
    SET is_resolved = true, resolved_at = now()
    WHERE module_reference = 'team_licenses'
      AND related_id = p_license_id
      AND is_resolved = false;

    RETURN v_row;
  END IF;

  v_next_due := (GREATEST(p_completed_on, v_row.due_date)
                 + (v_row.cycle_months || ' months')::interval)::date;

  UPDATE public.team_licenses
  SET due_date = v_next_due,
      last_completed_at = p_completed_on,
      ce_required = CASE
        WHEN v_row.ce_required = false AND v_row.initial_issue_date IS NOT NULL
          THEN true
        ELSE v_row.ce_required
      END
  WHERE id = p_license_id
  RETURNING * INTO v_row;

  UPDATE public.alerts
  SET is_resolved = true, resolved_at = now()
  WHERE module_reference = 'team_licenses'
    AND related_id = p_license_id
    AND is_resolved = false;

  DELETE FROM public.license_notification_log
  WHERE team_license_id = p_license_id;

  RETURN v_row;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.mark_license_complete(uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_license_complete(uuid, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_license_complete(uuid, date) TO authenticated, service_role;

UPDATE public.team t
SET user_id = 'f2b584dd-97ac-4575-a600-945893d6a491'::uuid
WHERE t.id = 'd7431075-d29f-4833-9503-430945894b04'::uuid
  AND t.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND t.user_id IS NULL;
