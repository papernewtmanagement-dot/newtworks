-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-28 16:23:11 UTC (ledger name: 20260728162500_v_card_balances_expose_alternate_last4) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260728162311.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Additive-only view change (CREATE OR REPLACE VIEW additive rule): append
-- alternate_last4 at end of SELECT so Financials CreditSection can show both
-- physical cards belonging to the same account (e.g. Chase Marketing 7762 + 7770).
CREATE OR REPLACE VIEW public.v_card_balances AS
 WITH latest_stmt AS (
         SELECT DISTINCT ON (statement_balances.account_code) statement_balances.account_code,
            statement_balances.statement_period_end,
            statement_balances.closing_balance,
            statement_balances.source,
            statement_balances.notes
           FROM statement_balances
          WHERE statement_balances.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND statement_balances.account_kind = 'credit'::text
          ORDER BY statement_balances.account_code, statement_balances.statement_period_end DESC
        ), ledger_since_stmt AS (
         SELECT coa_1.id AS chart_account_id,
            coa_1.account_code,
            round(sum(jl.credit) - sum(jl.debit), 2) AS activity_since_anchor,
            max(je.entry_date) AS last_entry_date,
            count(DISTINCT je.id) AS entry_count
           FROM credit_accounts ca_1
             JOIN chart_of_accounts coa_1 ON coa_1.id = ca_1.chart_account_id
             LEFT JOIN latest_stmt ls_1 ON ls_1.account_code = coa_1.account_code
             JOIN journal_lines jl ON jl.account_id = coa_1.id
             JOIN journal_entries je ON je.id = jl.journal_entry_id
          WHERE ca_1.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ca_1.is_active = true AND coa_1.account_type = 'liability'::text AND (ls_1.statement_period_end IS NULL OR je.entry_date > ls_1.statement_period_end)
          GROUP BY coa_1.id, coa_1.account_code
        )
 SELECT ca.agency_id,
    ca.id AS credit_account_id,
    ca.account_name,
    ca.institution,
    ca.account_type,
    ca.account_number_last4,
    ca.credit_limit,
    ca.interest_rate,
    ca.minimum_payment,
    ca.payment_due_day,
    ca.chart_account_id,
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
            WHEN ca.statement_close_day IS NULL THEN NULL::date
            ELSE compute_next_statement_close(COALESCE(ls.statement_period_end::timestamp without time zone, CURRENT_DATE - '35 days'::interval)::date, ca.statement_close_day)
        END AS next_statement_expected_date,
        CASE
            WHEN ca.statement_close_day IS NULL OR ls.statement_period_end IS NULL THEN NULL::boolean
            ELSE compute_next_statement_close(ls.statement_period_end, ca.statement_close_day) < (CURRENT_DATE - 3)
        END AS statement_overdue,
    ca.alternate_last4
   FROM credit_accounts ca
     LEFT JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
     LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
     LEFT JOIN ledger_since_stmt l ON l.chart_account_id = ca.chart_account_id
  WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ca.is_active = true
  ORDER BY ca.account_name;
