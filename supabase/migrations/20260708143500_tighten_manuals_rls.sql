-- Tighten RLS on public.manuals.
-- Prior state: two fully-permissive ALL/true/true policies (anon_all_manuals,
-- authenticated_all_manuals) letting any authenticated user CRUD any agency's
-- manuals via direct PostgREST call. Anon writes were already grant-blocked,
-- but authenticated writes had zero scope.
-- New state: mirrors the established pattern used by persistent_memory / team /
-- users -- anon+authenticated read all, authenticated write scoped to Peter's
-- agency_id. Role gating (owner/manager only) stays at the frontend, matching
-- the rest of the schema. Frontend ContentEditor is already ADMIN_ROLES-gated.

DROP POLICY IF EXISTS anon_all_manuals ON public.manuals;
DROP POLICY IF EXISTS authenticated_all_manuals ON public.manuals;

CREATE POLICY anon_read_manuals
  ON public.manuals
  FOR SELECT
  TO authenticated, anon
  USING (true);

CREATE POLICY authenticated_insert_manuals
  ON public.manuals
  FOR INSERT
  TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY authenticated_update_manuals
  ON public.manuals
  FOR UPDATE
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY authenticated_delete_manuals
  ON public.manuals
  FOR DELETE
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
