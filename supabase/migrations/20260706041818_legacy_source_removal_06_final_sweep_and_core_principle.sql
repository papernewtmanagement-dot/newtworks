-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:18:18 UTC (ledger name: legacy_source_removal_06_final_sweep_and_core_principle) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706041818.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- legacy-source removal — final sweep 06 + gated core_principle edit
-- Full-DB column scan surfaced 12 columns still holding legacy source refs after passes 1-5.
-- ============================================================================

-- 1. account_starting_balances.notes (3 rows)
UPDATE public.account_starting_balances
SET notes = REPLACE(notes, 'COA-', 'COA-')
WHERE notes LIKE '%COA-%';

-- 2. automation_run_log.output_summary (1 historical log row)
UPDATE public.automation_run_log
SET output_summary = REPLACE(output_summary, 'books_historical namespace', 'books_historical namespace')
WHERE output_summary ILIKE '%books_historical namespace%';

-- 3. bank_register_preliminary account-code refs (16 rows total)
UPDATE public.bank_register_preliminary
SET peter_credit_account = REPLACE(peter_credit_account, 'COA-', 'COA-')
WHERE peter_credit_account LIKE 'COA-%';
UPDATE public.bank_register_preliminary
SET peter_debit_account = REPLACE(peter_debit_account, 'COA-', 'COA-')
WHERE peter_debit_account LIKE 'COA-%';

-- 4. comp_category_map.notes (1 row) — "Sub-account COA-SUB-082... mirror in legacy source when convenient"
UPDATE public.comp_category_map
SET notes = REPLACE(REPLACE(notes, 'COA-SUB-', 'COA-SUB-'), 'mirror in legacy source when convenient', 'mirror to prior books when convenient')
WHERE notes ILIKE '%books_historical%';

-- 5. documents — file_type + upload_source labels (6 + 6 = 12 rows)
UPDATE public.documents
SET file_type = REPLACE(file_type, 'books_historical_', 'prior_books_')
WHERE file_type LIKE 'books_historical_%';
UPDATE public.documents
SET upload_source = REPLACE(upload_source, 'manual_books_historical_archive', 'manual_prior_books_archive')
WHERE upload_source LIKE 'manual_books_historical_archive%';

-- 6. journal_entries — created_by (4986 rows), reference_number (238), suspense_reason (1)
UPDATE public.journal_entries
SET created_by = 'books_historical_loader'
WHERE created_by = 'books_historical_loader';

UPDATE public.journal_entries
SET reference_number = REPLACE(reference_number, 'COA-', 'COA-')
WHERE reference_number LIKE '%COA-%';

UPDATE public.journal_entries
SET suspense_reason = REPLACE(suspense_reason, 'COA-', 'COA-')
WHERE suspense_reason LIKE '%COA-%';

-- 7. monthly_close_checklist (8 doc_label + 8 notes)
UPDATE public.monthly_close_checklist
SET doc_label = REPLACE(doc_label, 'COA-', 'COA-')
WHERE doc_label LIKE '%COA-%';
UPDATE public.monthly_close_checklist
SET notes = REPLACE(notes, 'COA-', 'COA-')
WHERE notes LIKE '%COA-%';

-- 8. core_principle edit (gated, Peter approved via ask_user_input_v0)
-- Rule id="cutover" in financial_health, priority 600.
UPDATE public.core_principles
SET content = REPLACE(content, 'imported from legacy source', 'imported from prior books'),
    updated_at = NOW()
WHERE id = 'd66f6111-aedb-4d32-86ee-000da66469a7'
  AND content LIKE '%imported from legacy source%';

-- 9. Rewrite the naming-scheme operational_rule I inserted earlier — Peter's directive
-- was "remove all references completely." Rule stays; just describes the scheme
-- prescriptively without naming the legacy source system.
UPDATE public.persistent_memory
SET title = 'BCC chart-and-source naming scheme (locked 2026-07-06)',
    content = E'<posture>BCC is agnostic of any legacy accounting source system. Machine-consumed labels never surface a prior-system name.</posture>\n\n<rule>\n- Account codes: COA-###, COA-SUB-###, COA-SUSP. Neutral prefix, no source-system reference.\n- Journal-entry source label for pre-cutover imports: books_historical_import_YYYY.\n- chart_of_accounts.chart_namespace value for the imported (pre-cutover-inherited) namespace: books_historical. Separate bcc_sf namespace holds BCC-native accounts.\n- v_trial_balance source_bucket derived value: books_historical. Same term for both the accounts namespace and the je source origin.\n- comp_category_map / comp_deduction_map columns: source_account_name, source_parent_account_name.\n- Variance view: v_variance_books_historical_vs_bcc with column books_historical_balance.\n- Settings key: drive_YYYY_prior_books_reports_folder_id.\n- journal_entries.created_by for pre-cutover-imported rows: books_historical_loader.\n- documents.file_type for imported statements: prior_books_balance_sheet / prior_books_general_ledger / prior_books_pnl. documents.upload_source: manual_prior_books_archive_session_N.\n</rule>\n\n<preserved>Literal merchant descriptions on CC-statement transaction records that name the payee vendor inline (Peter''s recurring accounting-software subscription): 18 je.description + 16 je.memo + 4 journal_lines.description rows. Transaction data, not system labels. Preserve.</preserved>\n\n<enforcement>Any future ingest, migration, or code that surfaces a legacy source-system name in a machine-consumed field is a bug.</enforcement>',
    updated_at = NOW()
WHERE title = 'BCC naming scheme (agnostic-of-legacy source, locked 2026-07-06)';
