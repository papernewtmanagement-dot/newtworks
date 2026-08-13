-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-11 21:54:42 UTC (ledger name: statements_explicit_statement_membership) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260811215442.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- A transaction belongs to the statement it is printed on. Card statements run
-- their period boundaries on POSTING date while statements.transaction_date holds
-- the date the charge was made, so a date-range join can never assign a charge
-- that was made just before a statement opened but printed on it.
-- This adds explicit membership. Date-range matching stays as the fallback for
-- every row that has not been pinned, so nothing already tying changes.

ALTER TABLE public.statements
  ADD COLUMN IF NOT EXISTS statement_balance_id uuid
  REFERENCES public.statement_balances(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_statements_statement_balance
  ON public.statements (statement_balance_id)
  WHERE statement_balance_id IS NOT NULL;

COMMENT ON COLUMN public.statements.statement_balance_id IS
  'Explicit statement membership. When set, the row reconciles ONLY against that statement and is excluded from date-range matching. Set it when the date the charge was made falls outside the statement period that prints the charge.';

CREATE OR REPLACE VIEW public.v_statement_reconciliation AS
 WITH txn_signed AS (
         SELECT s.id AS statement_row_id,
            sb_1.id AS statement_balance_id,
                CASE
                    WHEN sb_1.account_kind = 'bank'::text AND (s.transaction_type = ANY (ARRAY['deposit'::text, 'credit'::text, 'payment'::text, 'payment_or_credit'::text])) THEN abs(s.amount)
                    WHEN sb_1.account_kind = 'bank'::text AND (s.transaction_type = ANY (ARRAY['withdrawal'::text, 'charge'::text, 'debit'::text])) THEN - abs(s.amount)
                    WHEN sb_1.account_kind = 'credit'::text AND (s.transaction_type = ANY (ARRAY['charge'::text, 'debit'::text, 'withdrawal'::text])) THEN abs(s.amount)
                    WHEN sb_1.account_kind = 'credit'::text AND (s.transaction_type = ANY (ARRAY['deposit'::text, 'credit'::text, 'payment'::text, 'payment_or_credit'::text])) THEN - abs(s.amount)
                    ELSE NULL::numeric
                END AS signed_amount,
            sb_1.account_kind = 'bank'::text AND (s.transaction_type <> ALL (ARRAY['deposit'::text, 'credit'::text, 'payment'::text, 'payment_or_credit'::text, 'withdrawal'::text, 'charge'::text, 'debit'::text])) OR sb_1.account_kind = 'credit'::text AND (s.transaction_type <> ALL (ARRAY['charge'::text, 'debit'::text, 'withdrawal'::text, 'deposit'::text, 'credit'::text, 'payment'::text, 'payment_or_credit'::text])) OR s.transaction_type IS NULL AS is_unknown_type
           FROM statement_balances sb_1
             JOIN statements s ON (s.account_id IN ( SELECT a_1.id
                   FROM accounts a_1
                     JOIN chart_of_accounts coa2 ON coa2.id = a_1.chart_account_id
                  WHERE coa2.account_code = sb_1.account_code AND a_1.account_kind = sb_1.account_kind AND (sb_1.business_entity_id IS NULL OR a_1.business_entity_id = sb_1.business_entity_id)))
                AND (
                      s.statement_balance_id = sb_1.id
                   OR (s.statement_balance_id IS NULL
                       AND s.transaction_date >= sb_1.statement_period_start
                       AND s.transaction_date <= sb_1.statement_period_end)
                    )
          WHERE sb_1.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
        ), agg AS (
         SELECT txn_signed.statement_balance_id,
            count(*) AS transaction_count,
            sum(txn_signed.signed_amount) AS sum_signed,
            bool_or(txn_signed.is_unknown_type) AS has_unknown_type
           FROM txn_signed
          GROUP BY txn_signed.statement_balance_id
        )
 SELECT sb.id AS statement_balance_id,
    sb.account_code,
    coa.account_name,
    sb.account_kind,
    sb.business_entity_id,
    sb.statement_period_start,
    sb.statement_period_end,
    sb.opening_balance,
    sb.closing_balance,
    sb.opening_balance + COALESCE(a.sum_signed, 0::numeric) AS computed_closing,
    COALESCE(a.transaction_count, 0::bigint) AS transaction_count,
    sb.opening_balance + COALESCE(a.sum_signed, 0::numeric) - sb.closing_balance AS variance,
        CASE
            WHEN sb.opening_balance IS NULL THEN 'no_opening_balance'::text
            WHEN COALESCE(a.has_unknown_type, false) THEN 'unknown_transaction_type'::text
            WHEN COALESCE(a.transaction_count, 0::bigint) = 0 THEN 'no_transactions'::text
            WHEN abs(sb.opening_balance + COALESCE(a.sum_signed, 0::numeric) - sb.closing_balance) < 0.01 THEN 'ties'::text
            ELSE 'variance'::text
        END AS finding
   FROM statement_balances sb
     LEFT JOIN agg a ON a.statement_balance_id = sb.id
     LEFT JOIN chart_of_accounts coa ON coa.account_code = sb.account_code AND (sb.business_entity_id IS NOT NULL AND coa.business_entity_id = sb.business_entity_id OR sb.business_entity_id IS NULL)
  WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (sb.account_kind = ANY (ARRAY['bank'::text, 'credit'::text]));
