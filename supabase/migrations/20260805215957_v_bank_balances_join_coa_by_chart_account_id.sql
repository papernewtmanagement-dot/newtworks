-- v_bank_balances: join chart_of_accounts by bank_accounts.chart_account_id (the authoritative
-- stored link), not by account_name equality. The 2026-07-30 entity-prefix rekey migration
-- (phase3b_pss_shifts_and_all_remaining_rekeys_v2) renamed every linked chart-of-accounts row to
-- "PSS — ..." / "Personal — ...", so the old name-equality join matched zero rows and the Bank
-- Accounts tab derived $0.00 for every account (chart_account_id NULL -> no statement anchor,
-- no ledger activity). v_card_balances already joins by id; this brings the bank view to the same
-- pattern so chart-of-accounts renames can never zero it again. Output columns unchanged.
CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH active_accts AS (
  SELECT ba.id AS bank_account_id,
         ba.agency_id,
         ba.business_entity_id,
         ba.account_name,
         ba.institution,
         ba.account_type,
         ba.account_number_last4,
         ba.statement_close_day,
         coa.id AS chart_account_id,
         coa.account_code
  FROM bank_accounts ba
  LEFT JOIN chart_of_accounts coa ON coa.id = ba.chart_account_id
  WHERE ba.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ba.is_active = true
), latest_stmt AS (
  SELECT DISTINCT ON (statement_balances.account_code)
         statement_balances.account_code,
         statement_balances.statement_period_end,
         statement_balances.closing_balance,
         statement_balances.source,
         statement_balances.notes
  FROM statement_balances
  WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND statement_balances.account_kind = 'bank'::text
  ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
), ledger_since_stmt AS (
  SELECT a_1.account_code,
         round(sum(jl.debit) - sum(jl.credit), 2) AS activity_since_anchor,
         max(je.entry_date) AS last_entry_date,
         count(DISTINCT je.id) AS entry_count
  FROM active_accts a_1
  LEFT JOIN latest_stmt ls_1 ON ls_1.account_code = a_1.account_code
  JOIN journal_lines jl ON jl.account_id = a_1.chart_account_id
  JOIN journal_entries je ON je.id = jl.journal_entry_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND (ls_1.statement_period_end IS NULL OR je.entry_date > ls_1.statement_period_end)
  GROUP BY a_1.account_code
)
SELECT a.agency_id,
       a.bank_account_id,
       a.chart_account_id,
       a.account_code,
       a.account_name,
       a.institution,
       a.account_type,
       a.account_number_last4,
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
         WHEN a.statement_close_day IS NULL THEN NULL::date
         ELSE compute_next_statement_close(COALESCE(ls.statement_period_end::timestamp without time zone, CURRENT_DATE - '35 days'::interval)::date, a.statement_close_day)
       END AS next_statement_expected_date,
       CASE
         WHEN a.statement_close_day IS NULL OR ls.statement_period_end IS NULL THEN NULL::boolean
         ELSE compute_next_statement_close(ls.statement_period_end, a.statement_close_day) < (CURRENT_DATE - 3)
       END AS statement_overdue
FROM active_accts a
LEFT JOIN latest_stmt ls ON ls.account_code = a.account_code
LEFT JOIN ledger_since_stmt l ON l.account_code = a.account_code
ORDER BY a.account_name;
