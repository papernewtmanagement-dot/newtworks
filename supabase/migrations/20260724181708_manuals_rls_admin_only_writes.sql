-- Tighten manuals write access: only owner+manager can INSERT/UPDATE/DELETE.
-- Read stays open (anon+authenticated) per existing anon_read_manuals policy.
DROP POLICY IF EXISTS authenticated_update_manuals ON public.manuals;
DROP POLICY IF EXISTS authenticated_insert_manuals ON public.manuals;
DROP POLICY IF EXISTS authenticated_delete_manuals ON public.manuals;

CREATE POLICY admin_update_manuals ON public.manuals
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text,'manager'::text])
        AND u.agency_id = manuals.agency_id
        AND u.is_active = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text,'manager'::text])
        AND u.agency_id = manuals.agency_id
        AND u.is_active = true
    )
  );

CREATE POLICY admin_insert_manuals ON public.manuals
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text,'manager'::text])
        AND u.agency_id = manuals.agency_id
        AND u.is_active = true
    )
  );

CREATE POLICY admin_delete_manuals ON public.manuals
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text,'manager'::text])
        AND u.agency_id = manuals.agency_id
        AND u.is_active = true
    )
  );
