-- finrebuild_e1_statements_legacy_source_table_nullable
-- 2026-08-07 finance rebuild, Phase 1 blocker resolution.
--
-- statements.legacy_source_table was NOT NULL with no default, carrying
-- provenance ('bank_transactions' | 'credit_transactions') for the 1,542
-- rows created by the 2026-08-07 merge. Live intake (document-processor)
-- has no legacy source to record for new rows. Decision: drop NOT NULL,
-- no default. New rows leave the column NULL. NULL means "did not come
-- from the 2026-08-07 merge" — not an unknown/missing value to backfill.
-- Column is forensic only; no live code reads it.

ALTER TABLE public.statements
  ALTER COLUMN legacy_source_table DROP NOT NULL;

COMMENT ON COLUMN public.statements.legacy_source_table IS
  'Provenance from the 2026-08-07 merge only: bank_transactions or credit_transactions. NULL for every row created after the merge. Never populate with a sentinel — NULL is the correct value for live intake. Not read by any live code; forensic only.';
