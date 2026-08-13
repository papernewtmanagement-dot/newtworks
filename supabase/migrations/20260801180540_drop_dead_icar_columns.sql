-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 18:05:40 UTC (ledger name: drop_dead_icar_columns) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801180540.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS icar_letter_number_series,
  DROP COLUMN IF EXISTS icar_matrix_reasoning,
  DROP COLUMN IF EXISTS icar_verbal_reasoning,
  DROP COLUMN IF EXISTS icar_3d_rotation,
  DROP COLUMN IF EXISTS icar_total_score;
