-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 03:48:56 UTC (ledger name: legacy_source_removal_05_final_gaps) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706034856.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- LEGACY-SOURCE REMOVAL — Migration 5: close gaps found on second sweep
-- Tables missed on first pass: opening_balances, journal_lines, envelope_budget_targets,
-- settings.setting_key/description, automation_recipes.input_config/output_config,
-- bank_register_preliminary.
-- ============================================================================

-- === opening_balances (23 rows) ===
UPDATE public.opening_balances
SET account_code = REPLACE(account_code, 'COA-', 'COA-')
WHERE account_code LIKE 'COA-%';

UPDATE public.opening_balances
SET source = REPLACE(source, 'books_historical_', 'books_historical_')
WHERE source LIKE 'books_historical_%';

-- === envelope_budget_targets (15 rows) — must match chart_of_accounts codes ===
UPDATE public.envelope_budget_targets
SET account_code = REPLACE(account_code, 'COA-', 'COA-')
WHERE account_code LIKE 'COA-%';

-- === journal_lines.description (44 rows) — twin of journal_entries.description ===
UPDATE public.journal_lines
SET description = REPLACE(description, 'COA-', 'COA-')
WHERE description LIKE '%COA-%';

-- === bank_register_preliminary suggested account codes ===
UPDATE public.bank_register_preliminary
SET suggested_debit_account = REPLACE(suggested_debit_account, 'COA-', 'COA-')
WHERE suggested_debit_account LIKE 'COA-%';

UPDATE public.bank_register_preliminary
SET suggested_credit_account = REPLACE(suggested_credit_account, 'COA-', 'COA-')
WHERE suggested_credit_account LIKE 'COA-%';

-- === settings.setting_key — rename drive folder ID keys ===
UPDATE public.settings
SET setting_key = REPLACE(setting_key, '_books_historical_reports_folder_id', '_prior_books_reports_folder_id')
WHERE setting_key LIKE '%_books_historical_reports_folder_id';

-- === settings.description — scrub free text ===
UPDATE public.settings
SET description = 
  REPLACE(
  REPLACE(
  REPLACE(
    description,
    '/legacy source_Reports', '/Prior_Books_Reports'),
    'books_historical-namespace', 'books_historical namespace'),
    'legacy source', 'prior books')
WHERE description ILIKE '%books_historical%';

-- === automation_recipes.input_config JSON — COA-### account codes ===
UPDATE public.automation_recipes
SET input_config = REPLACE(input_config::text, 'COA-', 'COA-')::jsonb
WHERE input_config::text LIKE '%COA-%';

-- === automation_recipes.output_config JSON — "target_namespace": "books_historical" refs ===
UPDATE public.automation_recipes
SET output_config = REPLACE(REPLACE(output_config::text, '"target_namespace": "books_historical"', '"target_namespace": "books_historical"'), 'target namespace: books_historical', 'target namespace: books_historical')::jsonb
WHERE output_config::text ILIKE '%books_historical%';

-- Verify — all suspected columns should now be at 0
SELECT src, n FROM (
  (SELECT 'opening_balances.COA-' AS src, COUNT(*) AS n FROM opening_balances WHERE account_code LIKE 'COA-%')
  UNION ALL (SELECT 'opening_balances.books_historical_source', COUNT(*) FROM opening_balances WHERE source ILIKE '%books_historical%')
  UNION ALL (SELECT 'envelope_budget.COA-', COUNT(*) FROM envelope_budget_targets WHERE account_code LIKE 'COA-%')
  UNION ALL (SELECT 'journal_lines.COA-', COUNT(*) FROM journal_lines WHERE description LIKE '%COA-%')
  UNION ALL (SELECT 'brp.suggested_debit COA-', COUNT(*) FROM bank_register_preliminary WHERE suggested_debit_account LIKE 'COA-%')
  UNION ALL (SELECT 'settings.setting_key books_historical', COUNT(*) FROM settings WHERE setting_key ILIKE '%books_historical%')
  UNION ALL (SELECT 'settings.description books_historical', COUNT(*) FROM settings WHERE description ILIKE '%books_historical%')
  UNION ALL (SELECT 'ar.input_config books_historical', COUNT(*) FROM automation_recipes WHERE input_config::text ILIKE '%books_historical%')
  UNION ALL (SELECT 'ar.output_config books_historical', COUNT(*) FROM automation_recipes WHERE output_config::text ILIKE '%books_historical%')
) x;
