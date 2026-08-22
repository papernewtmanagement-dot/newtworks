-- Completes Peter's 2026-08-06 directive: financials readable by owner/manager only.
-- statement_balances was the 9th and last raw financial table, deferred during the
-- lockdown run because its single policy (statement_balances_agency_isolation) was
-- FOR ALL. Read cannot be narrowed by re-scoping: Postgres combines permissive
-- policies with OR, so adding an admin SELECT policy alongside an ALL policy would
-- leave the ALL policy still admitting staff. The ALL policy must therefore be
-- replaced by per-command policies.
--
-- Verified safe before applying: zero frontend references to statement_balances
-- (no app write path exists), and the only writers are the document-processor and
-- llm-queue-drainer edge functions, both of which run as service role and bypass
-- RLS entirely. Ingest is unaffected. Agency isolation is preserved on every
-- command; only SELECT gains the admin requirement.
--
-- Before: staff session read 94 rows (every bank + credit closing balance).
-- Expected after: staff 0, owner 94.

DROP POLICY statement_balances_agency_isolation ON public.statement_balances;

CREATE POLICY statement_balances_admin_read ON public.statement_balances
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
         AND public.is_agency_admin());

CREATE POLICY statement_balances_auth_insert ON public.statement_balances
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY statement_balances_auth_update ON public.statement_balances
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY statement_balances_auth_delete ON public.statement_balances
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
