-- Phase 2 of the RLS gap fix. After patching team + tasks in the prior
-- migration, an audit of every frontend .from(X).insert/update/delete/upsert
-- call against pg_policies surfaced 9 more tables silently dropping writes.
-- All nine have agency_id. Policies follow the existing authenticated_*_users
-- pattern: scoped to the Story Agency tenant, available to the authenticated
-- role. Policies are added per the table's actual frontend usage (no DELETE
-- policies added on tables the frontend doesn't delete from).

-- alerts: Financials calls .update() to mark alerts resolved
CREATE POLICY "authenticated_update_alerts" ON public.alerts
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- automation_recipes: Automations module .update()s recipe rows
CREATE POLICY "authenticated_update_automation_recipes" ON public.automation_recipes
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- bank_register_preliminary: CashRegister .update()s and needs SELECT too
CREATE POLICY "authenticated_select_bank_register_preliminary" ON public.bank_register_preliminary
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "authenticated_update_bank_register_preliminary" ON public.bank_register_preliminary
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- compliance_log: ComplianceCenter .insert()s log rows
CREATE POLICY "authenticated_insert_compliance_log" ON public.compliance_log
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- compliance_rules: ComplianceCenter .insert()s rules
CREATE POLICY "authenticated_insert_compliance_rules" ON public.compliance_rules
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- content_calendar: SocialMedia .update() and .upsert() (upsert = INSERT + UPDATE)
CREATE POLICY "authenticated_insert_content_calendar" ON public.content_calendar
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_update_content_calendar" ON public.content_calendar
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- monthly_close_checklist: MonthlyClose .update() toggles checkboxes
CREATE POLICY "authenticated_update_monthly_close_checklist" ON public.monthly_close_checklist
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- persistent_memory: PersistentMemory module .insert() and .update()
CREATE POLICY "authenticated_insert_persistent_memory" ON public.persistent_memory
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_update_persistent_memory" ON public.persistent_memory
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- txn_coding_rules: CashRegister .update() and .upsert(); needs SELECT too
CREATE POLICY "authenticated_select_txn_coding_rules" ON public.txn_coding_rules
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "authenticated_insert_txn_coding_rules" ON public.txn_coding_rules
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_update_txn_coding_rules" ON public.txn_coding_rules
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
