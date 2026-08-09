-- The finance rebuild (2026-08-08) dropped bank_transactions + credit_transactions and
-- replaced them with the unified statements table. v_ledger_dup_candidates was built on the
-- old pair and went away with them, but raise_ledger_dup_candidate_alerts() still reads it,
-- so Ledger Dup Candidate Pass has failed every run since with
-- "relation public.v_ledger_dup_candidates does not exist".
-- Rebuilt here against statements, preserving the original grouping contract
-- (agency, account, date, abs(amount)) and the exact column set the alert function expects:
-- agency_id, source_table, transaction_date, abs_amount, n, row_ids, amounts, descriptions.
-- security_invoker so the default-deny RLS on statements still applies to direct callers;
-- the SECURITY DEFINER alert function is unaffected.
CREATE OR REPLACE VIEW public.v_ledger_dup_candidates
WITH (security_invoker = true) AS
SELECT
  s.agency_id,
  'statements'::text                                      AS source_table,
  s.account_id,
  s.transaction_date,
  abs(s.amount)                                           AS abs_amount,
  count(*)::int                                           AS n,
  array_agg(s.id ORDER BY s.created_at, s.id)             AS row_ids,
  array_agg(s.amount ORDER BY s.created_at, s.id)         AS amounts,
  array_agg(COALESCE(s.description, '') ORDER BY s.created_at, s.id) AS descriptions
FROM public.statements s
WHERE s.superseded_by IS NULL
  AND s.amount IS NOT NULL
  AND abs(s.amount) > 0
GROUP BY s.agency_id, s.account_id, s.transaction_date, abs(s.amount)
HAVING count(*) > 1;
