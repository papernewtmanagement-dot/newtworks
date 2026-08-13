-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 03:41:15 UTC (ledger name: legacy_source_removal_03_rewrite_gl_writer_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706034115.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- LEGACY-SOURCE REMOVAL — Migration 3 of 3
-- Rewrite the 5 GL writer functions in-place: replace legacy-source string literals with
-- new labels/codes. Uses dynamic SQL so we don't have to inline 40KB of function
-- bodies in the migration file.
-- ============================================================================
DO $migration$
DECLARE
  fn_row record;
  new_def text;
BEGIN
  FOR fn_row IN
    SELECT proname, oid, pg_get_functiondef(oid) AS def
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('bank_gl_writer','cc_gl_writer','classify_je_via_chat','gl_entry_writer','payroll_gl_writer')
      AND pg_get_functiondef(oid) ILIKE '%books_historical%'
  LOOP
    new_def := fn_row.def;
    new_def := replace(new_def, 'v_chart_namespace := ''books_historical''', 'v_chart_namespace := ''books_historical''');
    new_def := replace(new_def, 'account_code = ''COA-SUSP''', 'account_code = ''COA-SUSP''');
    new_def := replace(new_def, '''searched_for'', ''COA-SUSP''', '''searched_for'', ''COA-SUSP''');
    new_def := replace(new_def, 'v_source_acct := ''COA-007''', 'v_source_acct := ''COA-007''');
    new_def := replace(new_def, '''Suspense (split offset pending)''', '''Suspense (split offset pending)''');
    new_def := replace(new_def, 'm.source_account_name', 'm.source_account_name');
    new_def := replace(new_def, 'm.source_parent_account_name', 'm.source_parent_account_name');
    IF new_def IS DISTINCT FROM fn_row.def THEN
      EXECUTE new_def;
      RAISE NOTICE 'Rewrote function: %', fn_row.proname;
    END IF;
  END LOOP;
END $migration$;
