DROP VIEW IF EXISTS public.v_statement_reconciliation;

CREATE VIEW public.v_statement_reconciliation AS
WITH txn_signed AS (
  SELECT
    s.id AS statement_row_id,
    sb.id AS statement_balance_id,
    CASE
      WHEN sb.account_kind = 'bank' AND s.transaction_type IN ('deposit','credit','payment','payment_or_credit') THEN abs(s.amount)
      WHEN sb.account_kind = 'bank' AND s.transaction_type IN ('withdrawal','charge','debit') THEN -abs(s.amount)
      WHEN sb.account_kind = 'credit' AND s.transaction_type IN ('charge','debit','withdrawal') THEN abs(s.amount)
      WHEN sb.account_kind = 'credit' AND s.transaction_type IN ('deposit','credit','payment','payment_or_credit') THEN -abs(s.amount)
      ELSE NULL
    END AS signed_amount,
    (
      (sb.account_kind = 'bank' AND s.transaction_type NOT IN ('deposit','credit','payment','payment_or_credit','withdrawal','charge','debit'))
      OR (sb.account_kind = 'credit' AND s.transaction_type NOT IN ('charge','debit','withdrawal','deposit','credit','payment','payment_or_credit'))
      OR s.transaction_type IS NULL
    ) AS is_unknown_type
  FROM public.statement_balances sb
  JOIN public.statements s
    ON s.account_id IN (
      SELECT a.id FROM public.accounts a
      JOIN public.chart_of_accounts coa2 ON coa2.id = a.chart_account_id
      WHERE coa2.account_code = sb.account_code
        AND a.account_kind = sb.account_kind
        AND (sb.business_entity_id IS NULL OR a.business_entity_id = sb.business_entity_id)
    )
    AND s.transaction_date >= sb.statement_period_start
    AND s.transaction_date <= sb.statement_period_end
  WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'
),
agg AS (
  SELECT
    statement_balance_id,
    count(*) AS transaction_count,
    sum(signed_amount) AS sum_signed,
    bool_or(is_unknown_type) AS has_unknown_type
  FROM txn_signed
  GROUP BY statement_balance_id
)
SELECT
  sb.id AS statement_balance_id,
  sb.account_code,
  coa.account_name,
  sb.account_kind,
  sb.business_entity_id,
  sb.statement_period_start,
  sb.statement_period_end,
  sb.opening_balance,
  sb.closing_balance,
  (sb.opening_balance + COALESCE(a.sum_signed, 0)) AS computed_closing,
  COALESCE(a.transaction_count, 0) AS transaction_count,
  ((sb.opening_balance + COALESCE(a.sum_signed, 0)) - sb.closing_balance) AS variance,
  CASE
    WHEN sb.opening_balance IS NULL THEN 'no_opening_balance'
    WHEN COALESCE(a.has_unknown_type, false) THEN 'unknown_transaction_type'
    WHEN COALESCE(a.transaction_count, 0) = 0 THEN 'no_transactions'
    WHEN abs((sb.opening_balance + COALESCE(a.sum_signed, 0)) - sb.closing_balance) < 0.01 THEN 'ties'
    ELSE 'variance'
  END AS finding
FROM public.statement_balances sb
LEFT JOIN agg a ON a.statement_balance_id = sb.id
LEFT JOIN public.chart_of_accounts coa
  ON coa.account_code = sb.account_code
  AND (
    (sb.business_entity_id IS NOT NULL AND coa.business_entity_id = sb.business_entity_id)
    OR (sb.business_entity_id IS NULL)
  )
WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND sb.account_kind IN ('bank','credit');

ALTER VIEW public.v_statement_reconciliation SET (security_invoker = true);
REVOKE ALL ON public.v_statement_reconciliation FROM anon, PUBLIC;
GRANT SELECT ON public.v_statement_reconciliation TO authenticated;
