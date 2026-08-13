-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 04:27:25 UTC (ledger name: legacy_source_removal_07_defaults_and_comments_retry) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706042725.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Final metadata sweep. Column default + 3 COMMENT ON entries.

-- 1. Column default on opening_balances.source
ALTER TABLE public.opening_balances
  ALTER COLUMN source SET DEFAULT 'books_historical_balance_sheet_2026ytd_pdf'::text;

-- 2. COMMENT ON documents.source_account_code
COMMENT ON COLUMN public.documents.source_account_code IS
  'GL account code (e.g. COA-007) inferred at intake. Used by drainer + GL poster to attribute bank txns to the correct source account. Resolved from sender email / subject via resolveSourceAccount() in document-processor index.ts.';

-- 3. COMMENT ON the specific gl_entry_writer overload (oid 18834, args: uuid, boolean)
COMMENT ON FUNCTION public.gl_entry_writer(p_agency_id uuid, p_dry_run boolean) IS
  'V2: Uses comp_category_map (revenue) and comp_deduction_map (deductions) for chart resolution. Splits comp_recap by comp_category prefix: deduction_* → expense, else → revenue. Pre-cutover archive-only. Suspense fallback for unmapped categories.';

-- 4. COMMENT ON v_balance_sheet view
COMMENT ON VIEW public.v_balance_sheet IS
  'Cumulative balance through entry_date for asset/liability/equity accounts. Window function gives running balance. Query LAST row per account for as-of snapshot. NOTE: pre-cutover imported entries (books_historical namespace) may use different sign convention; for accurate as-of balances pre-cutover, refer to original prior-books reports.';
