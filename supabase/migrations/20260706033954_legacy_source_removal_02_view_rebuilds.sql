-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 03:39:54 UTC (ledger name: legacy_source_removal_02_view_rebuilds) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706033954.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- LEGACY-SOURCE REMOVAL — Migration 2 of 3
-- Rebuild views dropped in migration 1 with new source labels + account codes.
-- ============================================================================

-- === v_trial_balance — swap 'books_historical_import%' pattern → 'books_historical_import%',
--     source_bucket label 'books_historical' → 'books_historical' ===
CREATE OR REPLACE VIEW public.v_trial_balance AS
SELECT je.agency_id,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.parent_account_id,
    parent.account_name AS parent_account_name,
    CASE
        WHEN je.source LIKE 'books_historical_import%' THEN 'books_historical'::text
        WHEN je.source = ANY (ARRAY['gl_entry_writer'::text, 'payroll_gl_writer'::text, 'bank_gl_writer'::text, 'cc_gl_writer'::text, 'document_processor'::text, 'document_processor_drainer'::text, 'claude_adjustment'::text]) THEN 'bcc_originating'::text
        ELSE 'other'::text
    END AS source_bucket,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS month_start,
    je.entry_date,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
    CASE
        WHEN coa.account_type = 'income'::text AND je.source LIKE 'books_historical_import%' THEN sum(jl.debit) - sum(jl.credit)
        WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text]) THEN sum(jl.debit) - sum(jl.credit)
        ELSE sum(jl.credit) - sum(jl.debit)
    END AS net_balance,
    count(DISTINCT je.id) AS entry_count
FROM journal_entries je
    JOIN journal_lines jl ON jl.journal_entry_id = je.id
    JOIN chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type,
    coa.parent_account_id, parent.account_name, je.source,
    (date_trunc('month'::text, je.entry_date::timestamp with time zone)), je.entry_date;

-- === v_bank_balances — swap the hardcoded COA-* array with COA-* ===
CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH ledger AS (
    SELECT je.agency_id,
        coa.id AS chart_account_id,
        coa.account_code,
        coa.account_name,
        round(sum(jl.debit) - sum(jl.credit), 2) AS balance_total,
        round(sum(jl.debit) FILTER (WHERE je.entry_date <= '2026-04-30'::date) - sum(jl.credit) FILTER (WHERE je.entry_date <= '2026-04-30'::date), 2) AS balance_anchor_0430,
        round(sum(jl.debit) FILTER (WHERE je.entry_date > '2026-04-30'::date) - sum(jl.credit) FILTER (WHERE je.entry_date > '2026-04-30'::date), 2) AS activity_since_anchor,
        max(je.entry_date) AS last_entry_date,
        count(DISTINCT je.id) AS entry_count
    FROM journal_entries je
        JOIN journal_lines jl ON jl.journal_entry_id = je.id
        JOIN chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_code = ANY (ARRAY['COA-001'::text, 'COA-024'::text, 'COA-002'::text, 'COA-003'::text, 'COA-004'::text, 'COA-005'::text, 'COA-006'::text, 'COA-007'::text])
    GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name
)
SELECT agency_id,
    chart_account_id,
    account_code,
    account_name,
    COALESCE(balance_anchor_0430, 0::numeric) AS balance_anchor_0430,
    COALESCE(activity_since_anchor, 0::numeric) AS activity_since_anchor,
    COALESCE(balance_total, 0::numeric) AS current_balance_derived,
    last_entry_date,
    entry_count,
    CASE
        WHEN COALESCE(balance_total, 0::numeric) < 0::numeric THEN true
        ELSE false
    END AS needs_review
FROM ledger;

-- === v_income_statement — swap 'books_historical_import%' pattern → 'books_historical_import%' ===
CREATE OR REPLACE VIEW public.v_income_statement AS
SELECT je.agency_id,
    EXTRACT(year FROM je.entry_date)::integer AS period_year,
    EXTRACT(month FROM je.entry_date)::integer AS period_month,
    EXTRACT(year FROM je.entry_date)::integer AS year,
    EXTRACT(month FROM je.entry_date)::integer AS month,
    to_char(je.entry_date::timestamp with time zone, 'YYYY-MM'::text) AS period,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS period_date,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.account_subtype,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
    CASE
        WHEN coa.account_type = 'income'::text AND je.source LIKE 'books_historical_import%' THEN sum(jl.debit) - sum(jl.credit)
        WHEN coa.account_type = 'income'::text THEN sum(jl.credit) - sum(jl.debit)
        WHEN coa.account_type = 'expense'::text THEN sum(jl.debit) - sum(jl.credit)
        ELSE 0::numeric
    END AS amount
FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.journal_entry_id
    JOIN chart_of_accounts coa ON coa.id = jl.account_id
WHERE coa.account_type = ANY (ARRAY['income'::text, 'expense'::text])
GROUP BY je.agency_id, je.entry_date, je.source, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.account_subtype;

-- === v_pl_rolled_up — no direct legacy source refs, just rebuild on top of new v_trial_balance ===
CREATE OR REPLACE VIEW public.v_pl_rolled_up AS
WITH leaf_balances AS (
    SELECT v_trial_balance.agency_id,
        v_trial_balance.account_id,
        v_trial_balance.account_code,
        v_trial_balance.account_name,
        v_trial_balance.account_type,
        COALESCE(v_trial_balance.parent_account_name, v_trial_balance.account_name) AS rollup_parent_name,
        v_trial_balance.parent_account_id,
        v_trial_balance.source_bucket,
        v_trial_balance.month_start,
        sum(v_trial_balance.net_balance) AS period_balance
    FROM v_trial_balance
    WHERE v_trial_balance.account_type = ANY (ARRAY['income'::text, 'expense'::text])
    GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code,
        v_trial_balance.account_name, v_trial_balance.account_type,
        (COALESCE(v_trial_balance.parent_account_name, v_trial_balance.account_name)),
        v_trial_balance.parent_account_id, v_trial_balance.source_bucket, v_trial_balance.month_start
)
SELECT agency_id,
    rollup_parent_name AS parent_account,
    account_type,
    source_bucket,
    month_start,
    to_char(month_start::timestamp with time zone, 'YYYY-MM'::text) AS month_label,
    sum(period_balance) AS total,
    count(DISTINCT account_id) AS account_count
FROM leaf_balances
GROUP BY agency_id, rollup_parent_name, account_type, source_bucket, month_start;

-- === v_variance_books_historical_vs_bcc — replaces v_variance_books_historical_vs_bcc,
--     with column `books_historical_balance` (was books_historical_balance) ===
CREATE OR REPLACE VIEW public.v_variance_books_historical_vs_bcc AS
WITH books_historical_data AS (
    SELECT v_trial_balance.agency_id,
        v_trial_balance.account_id,
        v_trial_balance.account_code,
        v_trial_balance.account_name,
        v_trial_balance.account_type,
        v_trial_balance.parent_account_name,
        v_trial_balance.month_start,
        sum(v_trial_balance.net_balance) AS books_historical_balance,
        sum(v_trial_balance.total_debit) AS books_historical_debit,
        sum(v_trial_balance.total_credit) AS books_historical_credit
    FROM v_trial_balance
    WHERE v_trial_balance.source_bucket = 'books_historical'::text
    GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code,
        v_trial_balance.account_name, v_trial_balance.account_type,
        v_trial_balance.parent_account_name, v_trial_balance.month_start
), bcc_data AS (
    SELECT v_trial_balance.agency_id,
        v_trial_balance.account_id,
        v_trial_balance.account_code,
        v_trial_balance.account_name,
        v_trial_balance.account_type,
        v_trial_balance.parent_account_name,
        v_trial_balance.month_start,
        sum(v_trial_balance.net_balance) AS bcc_balance,
        sum(v_trial_balance.total_debit) AS bcc_debit,
        sum(v_trial_balance.total_credit) AS bcc_credit
    FROM v_trial_balance
    WHERE v_trial_balance.source_bucket = 'bcc_originating'::text
    GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code,
        v_trial_balance.account_name, v_trial_balance.account_type,
        v_trial_balance.parent_account_name, v_trial_balance.month_start
)
SELECT COALESCE(h.agency_id, b.agency_id) AS agency_id,
    COALESCE(h.account_id, b.account_id) AS account_id,
    COALESCE(h.account_code, b.account_code) AS account_code,
    COALESCE(h.account_name, b.account_name) AS account_name,
    COALESCE(h.account_type, b.account_type) AS account_type,
    COALESCE(h.parent_account_name, b.parent_account_name) AS parent_account_name,
    COALESCE(h.month_start, b.month_start) AS month_start,
    to_char(COALESCE(h.month_start, b.month_start)::timestamp with time zone, 'YYYY-MM'::text) AS month_label,
    COALESCE(h.books_historical_balance, 0::numeric) AS books_historical_balance,
    COALESCE(b.bcc_balance, 0::numeric) AS bcc_balance,
    COALESCE(b.bcc_balance, 0::numeric) - COALESCE(h.books_historical_balance, 0::numeric) AS variance,
    CASE
        WHEN COALESCE(h.books_historical_balance, 0::numeric) = 0::numeric AND COALESCE(b.bcc_balance, 0::numeric) = 0::numeric THEN 0::numeric
        WHEN COALESCE(h.books_historical_balance, 0::numeric) = 0::numeric THEN NULL::numeric
        ELSE round((COALESCE(b.bcc_balance, 0::numeric) - COALESCE(h.books_historical_balance, 0::numeric)) / abs(h.books_historical_balance) * 100::numeric, 1)
    END AS variance_pct
FROM books_historical_data h
    FULL JOIN bcc_data b ON h.agency_id = b.agency_id AND h.account_id = b.account_id AND h.month_start = b.month_start;
