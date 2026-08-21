-- Drop existing views that conflict (must drop downstream views first)
DROP VIEW IF EXISTS public.v_variance_books_historical_vs_bcc CASCADE;
DROP VIEW IF EXISTS public.v_pl_rolled_up CASCADE;
DROP VIEW IF EXISTS public.v_balance_sheet CASCADE;
DROP VIEW IF EXISTS public.v_trial_balance CASCADE;

-- =============================================================================
-- v_trial_balance — Foundation view
-- =============================================================================
CREATE VIEW public.v_trial_balance AS
SELECT 
  je.agency_id,
  coa.id as account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.parent_account_id,
  parent.account_name as parent_account_name,
  CASE 
    WHEN je.source LIKE 'books_historical_import%' THEN 'books_historical'
    WHEN je.source IN ('gl_entry_writer','payroll_gl_writer','bank_gl_writer','cc_gl_writer','document_processor','document_processor_drainer') THEN 'bcc_originating'
    ELSE 'other'
  END as source_bucket,
  DATE_TRUNC('month', je.entry_date)::date as month_start,
  je.entry_date,
  SUM(jl.debit) as total_debit,
  SUM(jl.credit) as total_credit,
  CASE 
    WHEN coa.account_type IN ('asset','expense') THEN SUM(jl.debit) - SUM(jl.credit)
    ELSE SUM(jl.credit) - SUM(jl.debit)
  END as net_balance,
  COUNT(DISTINCT je.id) as entry_count
FROM journal_entries je
JOIN journal_lines jl ON jl.journal_entry_id = je.id
JOIN chart_of_accounts coa ON coa.id = jl.account_id
LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
GROUP BY 
  je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type, 
  coa.parent_account_id, parent.account_name,
  CASE 
    WHEN je.source LIKE 'books_historical_import%' THEN 'books_historical'
    WHEN je.source IN ('gl_entry_writer','payroll_gl_writer','bank_gl_writer','cc_gl_writer','document_processor','document_processor_drainer') THEN 'bcc_originating'
    ELSE 'other'
  END,
  DATE_TRUNC('month', je.entry_date),
  je.entry_date;

-- =============================================================================
-- v_pl_rolled_up
-- =============================================================================
CREATE VIEW public.v_pl_rolled_up AS
WITH leaf_balances AS (
  SELECT 
    agency_id,
    account_id,
    account_code,
    account_name,
    account_type,
    COALESCE(parent_account_name, account_name) as rollup_parent_name,
    parent_account_id,
    source_bucket,
    month_start,
    SUM(net_balance) as period_balance
  FROM v_trial_balance
  WHERE account_type IN ('income','expense')
  GROUP BY 
    agency_id, account_id, account_code, account_name, account_type,
    COALESCE(parent_account_name, account_name), parent_account_id, source_bucket, month_start
)
SELECT 
  agency_id,
  rollup_parent_name as parent_account,
  account_type,
  source_bucket,
  month_start,
  TO_CHAR(month_start, 'YYYY-MM') as month_label,
  SUM(period_balance) as total,
  COUNT(DISTINCT account_id) as account_count
FROM leaf_balances
GROUP BY agency_id, rollup_parent_name, account_type, source_bucket, month_start;

-- =============================================================================
-- v_variance_books_historical_vs_bcc
-- =============================================================================
CREATE VIEW public.v_variance_books_historical_vs_bcc AS
WITH books_historical_data AS (
  SELECT 
    agency_id, account_id, account_code, account_name, account_type,
    parent_account_name, month_start,
    SUM(net_balance) as books_historical_balance,
    SUM(total_debit) as books_historical_debit,
    SUM(total_credit) as books_historical_credit
  FROM v_trial_balance
  WHERE source_bucket = 'books_historical'
  GROUP BY agency_id, account_id, account_code, account_name, account_type, parent_account_name, month_start
),
bcc_data AS (
  SELECT 
    agency_id, account_id, account_code, account_name, account_type,
    parent_account_name, month_start,
    SUM(net_balance) as bcc_balance,
    SUM(total_debit) as bcc_debit,
    SUM(total_credit) as bcc_credit
  FROM v_trial_balance
  WHERE source_bucket = 'bcc_originating'
  GROUP BY agency_id, account_id, account_code, account_name, account_type, parent_account_name, month_start
)
SELECT 
  COALESCE(q.agency_id, b.agency_id) as agency_id,
  COALESCE(q.account_id, b.account_id) as account_id,
  COALESCE(q.account_code, b.account_code) as account_code,
  COALESCE(q.account_name, b.account_name) as account_name,
  COALESCE(q.account_type, b.account_type) as account_type,
  COALESCE(q.parent_account_name, b.parent_account_name) as parent_account_name,
  COALESCE(q.month_start, b.month_start) as month_start,
  TO_CHAR(COALESCE(q.month_start, b.month_start), 'YYYY-MM') as month_label,
  COALESCE(q.books_historical_balance, 0) as books_historical_balance,
  COALESCE(b.bcc_balance, 0) as bcc_balance,
  COALESCE(b.bcc_balance, 0) - COALESCE(q.books_historical_balance, 0) as variance,
  CASE 
    WHEN COALESCE(q.books_historical_balance, 0) = 0 AND COALESCE(b.bcc_balance, 0) = 0 THEN 0
    WHEN COALESCE(q.books_historical_balance, 0) = 0 THEN NULL
    ELSE ROUND(((COALESCE(b.bcc_balance, 0) - COALESCE(q.books_historical_balance, 0)) / ABS(q.books_historical_balance) * 100)::numeric, 1)
  END as variance_pct
FROM books_historical_data q
FULL OUTER JOIN bcc_data b 
  ON q.agency_id = b.agency_id 
 AND q.account_id = b.account_id 
 AND q.month_start = b.month_start;

-- =============================================================================
-- v_balance_sheet
-- =============================================================================
CREATE VIEW public.v_balance_sheet AS
SELECT 
  je.agency_id,
  coa.id as account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.parent_account_id,
  parent.account_name as parent_account_name,
  je.entry_date as as_of_date,
  SUM(jl.debit) OVER (
    PARTITION BY je.agency_id, coa.id 
    ORDER BY je.entry_date 
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) as cumulative_debit,
  SUM(jl.credit) OVER (
    PARTITION BY je.agency_id, coa.id 
    ORDER BY je.entry_date 
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) as cumulative_credit,
  CASE 
    WHEN coa.account_type IN ('asset','expense') THEN 
      SUM(jl.debit - jl.credit) OVER (
        PARTITION BY je.agency_id, coa.id 
        ORDER BY je.entry_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      )
    ELSE 
      SUM(jl.credit - jl.debit) OVER (
        PARTITION BY je.agency_id, coa.id 
        ORDER BY je.entry_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      )
  END as net_balance
FROM journal_entries je
JOIN journal_lines jl ON jl.journal_entry_id = je.id
JOIN chart_of_accounts coa ON coa.id = jl.account_id
LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
WHERE coa.account_type IN ('asset','liability','equity');

SELECT 'migration 028 v2 applied' as status;
