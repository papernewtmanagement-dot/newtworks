-- team_comp_pool_schedule still returned 182 rows to staff after gating its read
-- policy, because team_comp_pool_schedule_auth_write is FOR ALL and Postgres OR's
-- permissive policies — the ALL policy kept admitting SELECT. Same shape as the
-- statement_balances case. Replace the ALL policy with per-command write policies.
-- Writers are service-role edge functions (RLS bypassed), so no ingest impact.
DROP POLICY team_comp_pool_schedule_auth_write ON public.team_comp_pool_schedule;

CREATE POLICY team_comp_pool_schedule_auth_insert ON public.team_comp_pool_schedule
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY team_comp_pool_schedule_auth_update ON public.team_comp_pool_schedule
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY team_comp_pool_schedule_auth_delete ON public.team_comp_pool_schedule
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
