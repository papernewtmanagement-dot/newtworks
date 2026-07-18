-- team_comp_pool_schedule had RLS enabled with ZERO policies → authenticated role read 0 rows
-- → compute_pool_basis_and_envelope returned pool_pct=null → weekly_bonus_pool=0 for any app-level
-- write_weekly_comp_v2 caller. MCP/service_role bypassed RLS so live compute worked.
-- Mirroring the pattern used by agency_snapshot / weekly_cpr_reports / core_principles.

DROP POLICY IF EXISTS team_comp_pool_schedule_read ON public.team_comp_pool_schedule;
DROP POLICY IF EXISTS team_comp_pool_schedule_auth_write ON public.team_comp_pool_schedule;

CREATE POLICY team_comp_pool_schedule_read
  ON public.team_comp_pool_schedule
  FOR SELECT
  USING (true);

CREATE POLICY team_comp_pool_schedule_auth_write
  ON public.team_comp_pool_schedule
  FOR ALL
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
