CREATE OR REPLACE VIEW public.v_ledger_confirmation AS
SELECT
  l.id AS ledger_id,
  l.agency_id,
  l.entry_date,
  l.account_id,
  l.cash_register_id,
  l.statement_id,
  CASE
    WHEN l.statement_id IS NOT NULL THEN 'confirmed'
    WHEN EXISTS (
      SELECT 1
      FROM cash_register_preliminary c
      JOIN accounts ra ON (ra.account_number_last4 = c.account_last4 OR c.account_last4 = ANY(ra.alternate_last4s))
      JOIN statement_balances sb ON sb.agency_id = l.agency_id
        AND (sb.account_last4 = ra.account_number_last4 OR sb.account_last4 = ANY(COALESCE(ra.alternate_last4s, ARRAY[]::text[])))
        AND l.entry_date BETWEEN sb.statement_period_start AND sb.statement_period_end
      WHERE c.id = l.cash_register_id
    ) THEN 'not_on_statement'
    ELSE 'awaiting_statement'
  END AS confirmation
FROM ledger l
WHERE l.cash_register_id IS NOT NULL;
