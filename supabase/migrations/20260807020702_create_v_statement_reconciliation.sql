CREATE OR REPLACE VIEW public.v_statement_reconciliation AS
WITH resolved AS (
  SELECT
    sb.id AS statement_balance_id,
    sb.account_code,
    sb.account_kind,
    sb.business_entity_id,
    sb.statement_period_end,
    sb.closing_balance,
    coa.id AS coa_id,
    coa.account_name AS coa_account_name,
    COUNT(*) OVER (PARTITION BY sb.id) AS coa_match_count
  FROM public.statement_balances sb
  LEFT JOIN public.chart_of_accounts coa
    ON coa.account_code = sb.account_code
    AND (
      (sb.business_entity_id IS NOT NULL AND coa.business_entity_id = sb.business_entity_id)
      OR (sb.business_entity_id IS NULL)
    )
  WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND sb.statement_period_end IS NOT NULL
    AND sb.account_kind IN ('bank','credit')
),
dedup AS (
  -- one row per statement_balance_id: pick a single coa match (arbitrary among ties) but preserve the ambiguity flag
  SELECT DISTINCT ON (statement_balance_id)
    statement_balance_id,
    account_code,
    account_kind,
    business_entity_id,
    statement_period_end,
    closing_balance,
    coa_id,
    coa_account_name,
    (coa_match_count > 1) AS coa_match_ambiguous
  FROM resolved
  ORDER BY statement_balance_id, coa_id NULLS LAST
),
ledger AS (
  SELECT
    d.statement_balance_id,
    CASE
      WHEN d.account_kind = 'bank' THEN COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0)
      WHEN d.account_kind = 'credit' THEN COALESCE(SUM(jl.credit), 0) - COALESCE(SUM(jl.debit), 0)
    END AS ledger_balance
  FROM dedup d
  LEFT JOIN public.journal_lines jl
    ON jl.account_id = d.coa_id
  LEFT JOIN public.journal_entries je
    ON je.id = jl.journal_entry_id
    AND je.entry_date <= d.statement_period_end
  WHERE d.coa_id IS NOT NULL
    AND (jl.id IS NULL OR je.id IS NOT NULL)
  GROUP BY d.statement_balance_id, d.account_kind
),
base AS (
  SELECT
    d.statement_balance_id,
    d.account_code,
    d.coa_account_name AS account_name,
    d.account_kind,
    d.business_entity_id,
    d.statement_period_end,
    d.closing_balance,
    COALESCE(l.ledger_balance, 0) AS ledger_balance,
    d.coa_match_ambiguous
  FROM dedup d
  LEFT JOIN ledger l ON l.statement_balance_id = d.statement_balance_id
),
with_variance AS (
  SELECT *, (ledger_balance - closing_balance) AS variance
  FROM base
),
with_prior AS (
  SELECT
    *,
    LAG(variance) OVER (
      PARTITION BY account_code, business_entity_id
      ORDER BY statement_period_end
    ) AS prior_variance
  FROM with_variance
)
SELECT
  statement_balance_id,
  account_code,
  account_name,
  account_kind,
  business_entity_id,
  statement_period_end,
  closing_balance,
  ledger_balance,
  variance,
  prior_variance,
  CASE WHEN prior_variance IS NULL THEN NULL ELSE (variance - prior_variance) END AS variance_delta,
  coa_match_ambiguous,
  CASE
    WHEN coa_match_ambiguous THEN 'ambiguous_account'
    WHEN ABS(variance) <= 0.01 THEN 'ties'
    WHEN prior_variance IS NOT NULL AND ABS(variance - prior_variance) > 0.01 THEN 'in_period_error'
    ELSE 'baseline_offset'
  END AS finding
FROM with_prior;
