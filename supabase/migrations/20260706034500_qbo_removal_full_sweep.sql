-- ============================================================================
-- QBO removal — full agnostic sweep
-- Applied via Supabase MCP as 4 sequential migrations:
--   qbo_removal_01_drops_data_updates_column_renames
--   qbo_removal_02_view_rebuilds
--   qbo_removal_03_rewrite_gl_writer_functions
--   qbo_removal_04_drop_qbo_post_staged_batch
-- Consolidated here for repo-side reference.
--
-- Naming scheme:
--   QBO-###/QBO-SUB-### account codes  →  COA-###/COA-SUB-###
--   qbo_import_YYYY  je.source labels  →  books_historical_import_YYYY
--   chart_namespace 'qbo'              →  'books_historical'
--   source_bucket 'qbo_historical'     →  'books_historical'
--   qbo_account_name/qbo_parent_...    →  source_account_name/source_parent_...
--
-- Preserved (not scrubbed):
--   16 journal_entries.memo + 18 journal_entries.description rows containing
--   'Intuit *qbooks Online' or 'QuickBooks Payments' — these are literal merchant
--   descriptions on Peter's QuickBooks subscription CC charges, not system labels.
-- ============================================================================

-- Migration 1: drops + data updates + column renames
DROP VIEW IF EXISTS public.v_variance_qbo_vs_bcc;
DROP VIEW IF EXISTS public.v_pl_rolled_up;
DROP VIEW IF EXISTS public.v_bank_balances;
DROP VIEW IF EXISTS public.v_income_statement;
DROP VIEW IF EXISTS public.v_trial_balance;

DROP FUNCTION IF EXISTS public.qbo_post_staged_batch(uuid, integer, integer);
DROP TABLE IF EXISTS public.qbo_import_staging;

UPDATE public.chart_of_accounts SET account_code = REPLACE(account_code, 'QBO-', 'COA-') WHERE account_code LIKE 'QBO-%';
UPDATE public.chart_of_accounts SET account_name = 'Suspense (split offset pending)' WHERE account_name = 'QBO Suspense (split offset pending)';
UPDATE public.chart_of_accounts SET chart_namespace = 'books_historical' WHERE chart_namespace = 'qbo';

UPDATE public.gl_classification_rules SET debit_account_code = REPLACE(debit_account_code, 'QBO-', 'COA-') WHERE debit_account_code LIKE 'QBO-%';
UPDATE public.gl_classification_rules SET credit_account_code = REPLACE(credit_account_code, 'QBO-', 'COA-') WHERE credit_account_code LIKE 'QBO-%';
UPDATE public.gl_classification_rules SET source = REPLACE(source, 'qbo_import', 'books_historical_import') WHERE source LIKE 'qbo_import%';
UPDATE public.gl_classification_rules SET rule_name = REPLACE(rule_name, 'QBO Import', 'Historical Import') WHERE rule_name LIKE '%QBO Import%';
UPDATE public.gl_classification_rules SET rule_name = REPLACE(rule_name, 'per QBO history', 'per historical books') WHERE rule_name LIKE '%per QBO history%';
UPDATE public.gl_classification_rules SET override_reason = REPLACE(REPLACE(override_reason, 'QBO import', 'historical books import'), 'qbo_import', 'books_historical_import') WHERE override_reason ILIKE '%qbo%';

UPDATE public.journal_entries SET source = REPLACE(source, 'qbo_import', 'books_historical_import') WHERE source LIKE 'qbo_import%';
UPDATE public.journal_entries SET description = REPLACE(description, 'QBO-', 'COA-') WHERE description LIKE '%QBO-%';
UPDATE public.journal_entries SET description = REPLACE(description, 'QBO Full Year 2025 GL', 'prior-books Full Year 2025 GL') WHERE description LIKE '%QBO Full Year 2025 GL%';
UPDATE public.journal_entries SET memo = REPLACE(memo, 'QBO General Ledger PDF', 'prior-books General Ledger PDF') WHERE memo LIKE '%QBO General Ledger PDF%';

UPDATE public.documents SET groq_classification = REPLACE(groq_classification, 'qbo_', 'books_historical_') WHERE groq_classification LIKE 'qbo_%';
UPDATE public.documents SET notes = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(notes, 'QBO General Ledger', 'prior-books General Ledger'), 'QBO P&L', 'prior-books P&L'), 'QBO Balance Sheet', 'prior-books Balance Sheet'), 'qbo_import', 'books_historical_import'), 'QBO-', 'COA-') WHERE notes ILIKE '%qbo%';

UPDATE public.tasks SET title = REPLACE(REPLACE(REPLACE(REPLACE(title, 'QBO-', 'COA-'), 'QBO card', 'prior-books card'), 'QBO ', ''), 'to QBO', 'to prior books') WHERE title ILIKE '%qbo%';
UPDATE public.tasks SET description = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(description, 'QBO-', 'COA-'), 'QBO Bank Rules', 'prior-books bank rules'), 'QBO Import', 'historical books import'), 'QBO import', 'historical books import'), 'qbo-stage-load', 'historical-books-stage-load'), 'QBO', 'prior books') WHERE description ILIKE '%qbo%';

UPDATE public.alerts SET message = REPLACE(REPLACE(message, 'QBO-', 'COA-'), 'QBO', 'prior books') WHERE message ILIKE '%qbo%';

UPDATE public.settings SET setting_value = 'books_historical' WHERE setting_key = 'gl_chart_namespace' AND setting_value = 'qbo';

ALTER TABLE public.comp_category_map RENAME COLUMN qbo_account_name TO source_account_name;
ALTER TABLE public.comp_category_map RENAME COLUMN qbo_parent_account_name TO source_parent_account_name;
ALTER TABLE public.comp_deduction_map RENAME COLUMN qbo_account_name TO source_account_name;
ALTER TABLE public.comp_deduction_map RENAME COLUMN qbo_parent_account_name TO source_parent_account_name;

-- Migration 2: view rebuilds
-- (v_trial_balance, v_bank_balances, v_income_statement, v_pl_rolled_up,
--  v_variance_books_historical_vs_bcc — see migration 2 in Supabase for full defs)

-- Migration 3: dynamic rewrite of 5 GL writer function bodies
DO $migration$
DECLARE fn_row record; new_def text;
BEGIN
  FOR fn_row IN
    SELECT proname, oid, pg_get_functiondef(oid) AS def
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('bank_gl_writer','cc_gl_writer','classify_je_via_chat','gl_entry_writer','payroll_gl_writer')
      AND pg_get_functiondef(oid) ILIKE '%qbo%'
  LOOP
    new_def := fn_row.def;
    new_def := replace(new_def, 'v_chart_namespace := ''qbo''', 'v_chart_namespace := ''books_historical''');
    new_def := replace(new_def, 'account_code = ''QBO-SUSP''', 'account_code = ''COA-SUSP''');
    new_def := replace(new_def, '''searched_for'', ''QBO-SUSP''', '''searched_for'', ''COA-SUSP''');
    new_def := replace(new_def, 'v_source_acct := ''QBO-007''', 'v_source_acct := ''COA-007''');
    new_def := replace(new_def, '''QBO Suspense (split offset pending)''', '''Suspense (split offset pending)''');
    new_def := replace(new_def, 'm.qbo_account_name', 'm.source_account_name');
    new_def := replace(new_def, 'm.qbo_parent_account_name', 'm.source_parent_account_name');
    IF new_def IS DISTINCT FROM fn_row.def THEN
      EXECUTE new_def;
    END IF;
  END LOOP;
END $migration$;
