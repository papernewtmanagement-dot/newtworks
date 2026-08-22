CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (statement_balances.account_code)
    statement_balances.account_code,
    statement_balances.statement_period_end,
    statement_balances.opening_balance,
    statement_balances.closing_balance
  FROM statement_balances
  WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND statement_balances.account_kind = ANY (ARRAY['bank'::text, 'investment'::text])
  ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
),
base AS (
  SELECT
    a.agency_id,
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
    ls.closing_balance AS last_statement_closing_balance,
    a.chart_account_id,
    a.account_type
  FROM accounts a
    LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
    LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
  WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND a.account_kind = ANY (ARRAY['bank'::text, 'investment'::text])
),
pending AS (
  SELECT
    b.account_id,
    SUM(CASE WHEN c.direction = 'credit' THEN c.amount
              WHEN c.direction = 'debit' THEN -c.amount
              ELSE 0 END) AS pending_delta
  FROM base b
    JOIN cash_register_preliminary c
      ON c.agency_id = b.agency_id
     AND (c.account_last4 = b.account_number_last4 OR c.account_last4 = ANY(b.alternate_last4s))
     AND (b.last_statement_period_end IS NULL OR c.txn_date > b.last_statement_period_end)
  GROUP BY b.account_id
)
SELECT
  b.agency_id,
  b.business_entity_id,
  b.account_id,
  b.account_name,
  b.institution,
  b.account_number_last4,
  b.alternate_last4s,
  b.account_code,
  b.account_kind,
  b.statement_close_day,
  b.is_active,
  b.last_statement_period_end,
  b.last_statement_opening_balance,
  CASE WHEN b.last_statement_period_end IS NULL THEN NULL
       ELSE b.last_statement_closing_balance + COALESCE(p.pending_delta, 0) END AS current_balance_derived,
  compute_next_statement_close(b.statement_close_day, b.last_statement_period_end) AS next_statement_expected,
  CURRENT_DATE - b.last_statement_period_end AS days_since_close,
  b.statement_close_day IS NOT NULL
    AND compute_next_statement_close(b.statement_close_day, b.last_statement_period_end) < CURRENT_DATE AS is_overdue,
  b.chart_account_id,
  b.account_type,
  (CASE WHEN b.last_statement_period_end IS NULL THEN NULL
        ELSE b.last_statement_closing_balance + COALESCE(p.pending_delta, 0) END) < 0::numeric AS needs_review,
  b.last_statement_closing_balance,
  COALESCE(p.pending_delta, 0) AS pending_activity_since_statement
FROM base b
  LEFT JOIN pending p ON p.account_id = b.account_id
ORDER BY b.account_name;
