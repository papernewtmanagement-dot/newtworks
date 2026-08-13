-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:26:28 UTC (ledger name: flag_cash_register_transfer_pairs) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810222628.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

UPDATE public.cash_register_preliminary
SET status = 'possible_transfer', updated_at = now()
WHERE id IN (
  '22d233d3-671e-484b-b82f-3a4e621ac1c4','c09871c0-0952-4ad8-9327-c5694fdbb78f',
  '20e73dbe-65d7-4a72-a4f0-5d10e08d589e','f90a0ab0-79e0-4c63-965b-7fc476c38620',
  '2dd435ad-6709-4129-a395-e860f3c6c52d','ff3807ba-bc75-46e7-9610-a0b3b9a6c241',
  '32b90821-aeac-4b6f-8d25-750c33469459','886799fd-0dea-4733-b4e4-491b3398ad91',
  '1efb1b4b-7fc1-4d12-ad1d-3efa74005056','d3c03104-46b4-4b55-b316-050f1eb9a4f6',
  '8343a6ae-fdf2-4f48-a647-418924834c38','8f9138e1-81a9-4dae-90d8-bd018102dd8b',
  '0542894b-f9f7-4903-8db5-918c32fe4d02','7019c0c9-e50a-4427-8556-5d8936d846b4',
  '035eef7a-4b85-4c18-97a3-e53a27377258','787fbe30-6151-4b0b-b8c7-c119d829f19f'
);
