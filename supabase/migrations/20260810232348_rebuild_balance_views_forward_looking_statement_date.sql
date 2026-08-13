-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 23:23:48 UTC (ledger name: rebuild_balance_views_forward_looking_statement_date) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810232348.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DROP VIEW IF EXISTS public.v_card_balances;
DROP VIEW IF EXISTS public.v_bank_balances;

CREATE VIEW public.v_card_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (statement_balances.account_code)
    statement_balances.account_code,
    statement_balances.statement_period_end,
    statement_balances.opening_balance,
    statement_balances.closing_balance
  FROM statement_balances
  WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND statement_balances.account_kind = 'credit'::text
  ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
)
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
  ls.closing_balance AS current_balance_derived,
  public.compute_next_statement_close(a.statement_close_day, ls.statement_period_end) AS next_statement_expected,
  CURRENT_DATE - ls.statement_period_end AS days_since_close,
  (a.statement_close_day IS NOT NULL
    AND public.compute_next_statement_close(a.statement_close_day, ls.statement_period_end) < CURRENT_DATE
  ) AS is_overdue,
  a.credit_limit,
  a.minimum_payment,
  a.payment_due_day,
  a.credit_limit - ls.closing_balance AS available_credit,
  a.chart_account_id,
  a.account_type,
  a.interest_rate,
  a.account_number_last4 IS NULL AS needs_last4,
  ls.closing_balance < 0::numeric AS needs_review
FROM accounts a
LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND a.account_kind = 'credit'::text
ORDER BY a.account_name;

CREATE VIEW public.v_bank_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (statement_balances.account_code)
    statement_balances.account_code,
    statement_balances.statement_period_end,
    statement_balances.opening_balance,
    statement_balances.closing_balance
  FROM statement_balances
  WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND statement_balances.account_kind = 'bank'::text
  ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
)
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
  ls.closing_balance AS current_balance_derived,
  public.compute_next_statement_close(a.statement_close_day, ls.statement_period_end) AS next_statement_expected,
  CURRENT_DATE - ls.statement_period_end AS days_since_close,
  (a.statement_close_day IS NOT NULL
    AND public.compute_next_statement_close(a.statement_close_day, ls.statement_period_end) < CURRENT_DATE
  ) AS is_overdue,
  a.chart_account_id,
  a.account_type,
  ls.closing_balance < 0::numeric AS needs_review
FROM accounts a
LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND a.account_kind = 'bank'::text
ORDER BY a.account_name;
