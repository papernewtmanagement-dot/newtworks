-- DROP + CREATE (Postgres won't reorder view columns via CREATE OR REPLACE)

DROP VIEW IF EXISTS public.v_bank_balances CASCADE;
DROP VIEW IF EXISTS public.v_card_balances CASCADE;

-- Helper: compute expected next close date given a base date + close day-of-month
CREATE OR REPLACE FUNCTION public.compute_next_statement_close(
  base_date date,
  close_day smallint
) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  WITH months AS (
    SELECT gs::date AS month_start
    FROM generate_series(
      date_trunc('month', base_date)::date,
      date_trunc('month', base_date + interval '2 months')::date,
      interval '1 month'
    ) gs
  ),
  candidates AS (
    SELECT (month_start + (LEAST(close_day, extract(day from (month_start + interval '1 month - 1 day'))::int) - 1) * interval '1 day')::date AS close_date
    FROM months
  )
  SELECT close_date FROM candidates
  WHERE close_date > base_date
  ORDER BY close_date
  LIMIT 1;
$$;

CREATE VIEW public.v_bank_balances AS
WITH active_accts AS (
  SELECT ba.id AS bank_account_id, ba.agency_id, ba.business_entity_id,
         ba.account_name, ba.institution, ba.account_type, ba.account_number_last4,
         ba.statement_close_day,
         coa.id AS chart_account_id, coa.account_code
  FROM bank_accounts ba
  LEFT JOIN chart_of_accounts coa
    ON coa.account_name = ba.account_name AND coa.account_type = 'asset'::text
  WHERE ba.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ba.is_active = true
),
latest_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code, statement_period_end, closing_balance, source, notes
  FROM statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND account_kind = 'bank'
  ORDER BY account_code, statement_period_end DESC
),
ledger_since_stmt AS (
  SELECT a.account_code,
         round(sum(jl.debit) - sum(jl.credit), 2) AS activity_since_anchor,
         max(je.entry_date) AS last_entry_date,
         count(DISTINCT je.id) AS entry_count
  FROM active_accts a
  LEFT JOIN latest_stmt ls ON ls.account_code = a.account_code
  JOIN chart_of_accounts coa ON coa.account_code = a.account_code
  JOIN journal_lines jl ON jl.account_id = coa.id
  JOIN journal_entries je ON je.id = jl.journal_entry_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND coa.account_type = 'asset'::text
    AND (ls.statement_period_end IS NULL OR je.entry_date > ls.statement_period_end)
  GROUP BY a.account_code
)
SELECT
  a.agency_id, a.bank_account_id, a.chart_account_id, a.account_code, a.account_name,
  a.institution, a.account_type, a.account_number_last4,
  COALESCE(ls.closing_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  round(COALESCE(ls.closing_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric), 2) AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0::bigint) AS entry_count,
  ls.statement_period_end IS NULL AS needs_statement,
  (COALESCE(ls.closing_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric)) < 0::numeric AS needs_review,
  a.business_entity_id,
  ls.statement_period_end AS last_statement_close_date,
  ls.closing_balance AS last_statement_balance,
  ls.source AS last_statement_source,
  ls.notes AS last_statement_notes,
  a.statement_close_day,
  CASE
    WHEN a.statement_close_day IS NULL THEN NULL
    ELSE public.compute_next_statement_close(
      COALESCE(ls.statement_period_end, CURRENT_DATE - interval '35 days')::date,
      a.statement_close_day
    )
  END AS next_statement_expected_date,
  CASE
    WHEN a.statement_close_day IS NULL OR ls.statement_period_end IS NULL THEN NULL
    ELSE (public.compute_next_statement_close(ls.statement_period_end::date, a.statement_close_day) < CURRENT_DATE - 3)
  END AS statement_overdue
FROM active_accts a
LEFT JOIN latest_stmt ls ON ls.account_code = a.account_code
LEFT JOIN ledger_since_stmt l ON l.account_code = a.account_code
ORDER BY a.account_name;


CREATE VIEW public.v_card_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code, statement_period_end, closing_balance, source, notes
  FROM statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND account_kind = 'credit'
  ORDER BY account_code, statement_period_end DESC
),
ledger_since_stmt AS (
  SELECT coa.id AS chart_account_id, coa.account_code,
         round(sum(jl.credit) - sum(jl.debit), 2) AS activity_since_anchor,
         max(je.entry_date) AS last_entry_date,
         count(DISTINCT je.id) AS entry_count
  FROM credit_accounts ca
  JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
  LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
  JOIN journal_lines jl ON jl.account_id = coa.id
  JOIN journal_entries je ON je.id = jl.journal_entry_id
  WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ca.is_active = true
    AND coa.account_type = 'liability'::text
    AND (ls.statement_period_end IS NULL OR je.entry_date > ls.statement_period_end)
  GROUP BY coa.id, coa.account_code
)
SELECT
  ca.agency_id, ca.id AS credit_account_id, ca.account_name, ca.institution,
  ca.account_type, ca.account_number_last4, ca.credit_limit, ca.interest_rate,
  ca.minimum_payment, ca.payment_due_day, ca.chart_account_id,
  COALESCE(ls.closing_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  round(COALESCE(ls.closing_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric), 2) AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0::bigint) AS entry_count,
  ca.account_number_last4 IS NULL AS needs_last4,
  (COALESCE(ls.closing_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric)) < 0::numeric AS needs_review,
  ca.business_entity_id,
  ls.statement_period_end AS last_statement_close_date,
  ls.closing_balance AS last_statement_balance,
  ls.source AS last_statement_source,
  ls.notes AS last_statement_notes,
  ca.statement_close_day,
  CASE
    WHEN ca.statement_close_day IS NULL THEN NULL
    ELSE public.compute_next_statement_close(
      COALESCE(ls.statement_period_end, CURRENT_DATE - interval '35 days')::date,
      ca.statement_close_day
    )
  END AS next_statement_expected_date,
  CASE
    WHEN ca.statement_close_day IS NULL OR ls.statement_period_end IS NULL THEN NULL
    ELSE (public.compute_next_statement_close(ls.statement_period_end::date, ca.statement_close_day) < CURRENT_DATE - 3)
  END AS statement_overdue
FROM credit_accounts ca
LEFT JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
LEFT JOIN ledger_since_stmt l ON l.chart_account_id = ca.chart_account_id
WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND ca.is_active = true
ORDER BY ca.account_name;
