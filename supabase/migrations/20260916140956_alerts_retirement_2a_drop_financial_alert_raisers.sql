-- Retire the alerts table, part 2a of 3.
-- The four financial alert raisers are dropped. The Financials Reconciliation
-- tab computes the same findings live from views, so writing them into a table
-- only ever produced rows that went stale. Their recipes are switched off
-- rather than deleted because automation_run_log holds their run history.

UPDATE public.automation_recipes
SET is_active = false
WHERE internal_handler IN (
  'fn_check_statement_reconciliation',
  'raise_not_on_statement_alerts',
  'run_ledger_dup_pass',
  'gl_rule_dormancy_audit_recipe'
);

DROP FUNCTION IF EXISTS public.fn_check_statement_reconciliation(uuid, uuid);
DROP FUNCTION IF EXISTS public.raise_not_on_statement_alerts(uuid, uuid);
DROP FUNCTION IF EXISTS public.gl_rule_dormancy_audit_recipe(uuid, uuid);
DROP FUNCTION IF EXISTS public.run_ledger_dup_pass(uuid, uuid);
DROP FUNCTION IF EXISTS public.raise_ledger_dup_candidate_alerts(uuid);
DROP FUNCTION IF EXISTS public.audit_dormant_gl_classification_rules(uuid, interval);
