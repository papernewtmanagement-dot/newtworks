-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 03:38:51 UTC (ledger name: legacy_source_removal_01_drops_data_updates_column_renames) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706033851.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- LEGACY-SOURCE REMOVAL — Migration 1 of 3
-- Removes legacy-source branding from the DB. See core_principle "financial_health" cutover.
-- Scheme: COA- account codes → COA-; books_historical_import*/books_historical labels →
-- books_historical_*; column source_account_name → source_account_name.
-- ============================================================================

-- === 1. Drop dependent views (rebuilt in migration 2 with new labels) ===
DROP VIEW IF EXISTS public.v_variance_books_historical_vs_bcc;
DROP VIEW IF EXISTS public.v_pl_rolled_up;
DROP VIEW IF EXISTS public.v_bank_balances;
DROP VIEW IF EXISTS public.v_income_statement;
DROP VIEW IF EXISTS public.v_trial_balance;

-- === 2. Drop empty staging + paired dead function ===
DROP FUNCTION IF EXISTS public.legacy_post_staged_batch();
DROP TABLE IF EXISTS public.legacy_import_staging;

-- === 3. Chart of accounts — account_code prefix + Suspense name + namespace ===
UPDATE public.chart_of_accounts
SET account_code = REPLACE(account_code, 'COA-', 'COA-')
WHERE account_code LIKE 'COA-%';

UPDATE public.chart_of_accounts
SET account_name = 'Suspense (split offset pending)'
WHERE account_name = 'Suspense (split offset pending)';

UPDATE public.chart_of_accounts
SET chart_namespace = 'books_historical'
WHERE chart_namespace = 'books_historical';

-- === 4. GL classification rules ===
UPDATE public.gl_classification_rules
SET debit_account_code = REPLACE(debit_account_code, 'COA-', 'COA-')
WHERE debit_account_code LIKE 'COA-%';

UPDATE public.gl_classification_rules
SET credit_account_code = REPLACE(credit_account_code, 'COA-', 'COA-')
WHERE credit_account_code LIKE 'COA-%';

UPDATE public.gl_classification_rules
SET source = REPLACE(source, 'books_historical_import', 'books_historical_import')
WHERE source LIKE 'books_historical_import%';

UPDATE public.gl_classification_rules
SET rule_name = REPLACE(rule_name, 'Legacy-source Import', 'Historical Import')
WHERE rule_name LIKE '%Legacy-source Import%';

UPDATE public.gl_classification_rules
SET rule_name = REPLACE(rule_name, 'per legacy-source history', 'per historical books')
WHERE rule_name LIKE '%per legacy-source history%';

UPDATE public.gl_classification_rules
SET override_reason = REPLACE(REPLACE(override_reason, 'legacy-source import', 'historical books import'), 'books_historical_import', 'books_historical_import')
WHERE override_reason ILIKE '%books_historical%';

-- === 5. Journal entries — source label (4987 rows) + description (29) + memo (1 system-authored) ===
UPDATE public.journal_entries
SET source = REPLACE(source, 'books_historical_import', 'books_historical_import')
WHERE source LIKE 'books_historical_import%';

UPDATE public.journal_entries
SET description = REPLACE(description, 'COA-', 'COA-')
WHERE description LIKE '%COA-%';

UPDATE public.journal_entries
SET memo = REPLACE(memo, 'legacy source General Ledger PDF', 'prior-books General Ledger PDF')
WHERE memo LIKE '%legacy source General Ledger PDF%';

-- Note: 16 rows with memo containing 'Intuit *books_historicaloks' are LEFT UNTOUCHED — these
-- are literal merchant descriptions from CC statements (a QuickBooks subscription
-- transaction), not system-authored legacy source references. Preserving them keeps the
-- accounting record faithful to source transaction text.

-- === 6. Documents ===
UPDATE public.documents
SET groq_classification = REPLACE(groq_classification, 'books_historical_', 'books_historical_')
WHERE groq_classification LIKE 'books_historical_%';

UPDATE public.documents
SET notes = REPLACE(REPLACE(REPLACE(REPLACE(
        notes,
        'legacy source General Ledger', 'prior-books General Ledger'),
        'legacy source P&L',            'prior-books P&L'),
        'legacy source Balance Sheet',  'prior-books Balance Sheet'),
        'books_historical_import',         'books_historical_import')
WHERE notes ILIKE '%books_historical%';

-- === 7. Tasks — 4 titles + 15 descriptions ===
UPDATE public.tasks
SET title = REPLACE(REPLACE(REPLACE(REPLACE(
        title,
        'COA-',       'COA-'),
        'legacy-source card',   'prior-books card'),
        'legacy source ',       ''),
        'to legacy source',     'to prior books')
WHERE title ILIKE '%books_historical%';

UPDATE public.tasks
SET description = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        description,
        'COA-',              'COA-'),
        'legacy-source bank rules',    'prior-books bank rules'),
        'Legacy-source Import',        'historical books import'),
        'legacy-source import',        'historical books import'),
        'legacy source',               'prior books')
WHERE description ILIKE '%books_historical%';

-- === 8. Alerts ===
UPDATE public.alerts
SET message = REPLACE(REPLACE(message, 'COA-', 'COA-'), 'legacy source', 'prior books')
WHERE message ILIKE '%books_historical%';

-- === 9. Settings — namespace default ===
UPDATE public.settings
SET setting_value = 'books_historical'
WHERE setting_key = 'gl_chart_namespace' AND setting_value = 'books_historical';

-- === 10. Rename books_historical_* columns on comp maps ===
ALTER TABLE public.comp_category_map RENAME COLUMN source_account_name TO source_account_name;
ALTER TABLE public.comp_category_map RENAME COLUMN source_parent_account_name TO source_parent_account_name;
ALTER TABLE public.comp_deduction_map RENAME COLUMN source_account_name TO source_account_name;
ALTER TABLE public.comp_deduction_map RENAME COLUMN source_parent_account_name TO source_parent_account_name;
