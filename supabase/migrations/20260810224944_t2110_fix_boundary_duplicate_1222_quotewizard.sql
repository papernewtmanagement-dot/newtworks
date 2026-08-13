-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:49:44 UTC (ledger name: t2110_fix_boundary_duplicate_1222_quotewizard) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810224944.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Remove the erroneous duplicate I inserted (transaction already existed, just misdated for reconciliation)
DELETE FROM public.statements WHERE id = '92afc69d-da58-4cd9-9b42-75f36078cb40';

-- Apply diagnostic rule (c): repost the existing boundary-date row under the statement's open date,
-- preserving the printed transaction date in notes. Original row id 47519588-5e23-49f8-b11c-6b1b15cbe5fa.
UPDATE public.statements
SET transaction_date = '2025-12-23',
    notes = COALESCE(notes,'') || ' | Diagnostic rule (c): reposted from printed date 2025-12-22 (precedes statement open date 2025-12-23) to open date per decided boundary-charge policy (matches Feb 2026, migration 20260809072327).'
WHERE id = '47519588-5e23-49f8-b11c-6b1b15cbe5fa';
