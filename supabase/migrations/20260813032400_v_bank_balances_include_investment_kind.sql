CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (statement_balances.account_code) statement_balances.account_code,
    statement_balances.statement_period_end,
    statement_balances.opening_balance,
    statement_balances.closing_balance
  FROM statement_balances
  WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND statement_balances.account_kind = ANY (ARRAY['bank'::text, 'investment'::text])
  ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
)
SELECT a.agency_id,
  a.business_entity_id,
  a.id AS account_id,
  a.account_name,
  a.institution,
  a.account_number_last4,
  a.alternate_last4s,
  coa.account_code,
  a.account_kind,
  a.statement_close_day,
  a.is_active,
  ls.statement_period_end AS last_statement_period_end,
  ls.opening_balance AS last_statement_opening_balance,
  ls.closing_balance AS current_balance_derived,
  compute_next_statement_close(a.statement_close_day, ls.statement_period_end) AS next_statement_expected,
  CURRENT_DATE - ls.statement_period_end AS days_since_close,
  a.statement_close_day IS NOT NULL AND compute_next_statement_close(a.statement_close_day, ls.statement_period_end) < CURRENT_DATE AS is_overdue,
  a.chart_account_id,
  a.account_type,
  ls.closing_balance < 0::numeric AS needs_review
FROM accounts a
  LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
  LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND a.account_kind = ANY (ARRAY['bank'::text, 'investment'::text])
ORDER BY a.account_name;

-- Fidelity HSA is genuinely an investment account, not a plain bank account
UPDATE public.accounts SET account_kind = 'investment' WHERE account_name = 'Fidelity HSA';

