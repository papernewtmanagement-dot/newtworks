-- Peter directive 2026-08-06: default-deny. core_principles becomes owner/manager only
-- for BOTH read and write. The prior FOR ALL policy keyed only on agency_id let any
-- signed-in staff member edit or delete principles rows; a FOR ALL policy also keeps
-- admitting SELECT no matter what read policy sits beside it, so it must be dropped
-- and replaced with per-command write policies.
DROP POLICY IF EXISTS core_principles_select ON public.core_principles;
DROP POLICY IF EXISTS core_principles_auth_write ON public.core_principles;

CREATE POLICY core_principles_admin_read ON public.core_principles
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

CREATE POLICY core_principles_admin_insert ON public.core_principles
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

CREATE POLICY core_principles_admin_update ON public.core_principles
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

CREATE POLICY core_principles_admin_delete ON public.core_principles
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
