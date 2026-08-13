-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 15:28:48 UTC (ledger name: create_transaction_tags_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730152848.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.transaction_tags (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id UUID NOT NULL,
  journal_line_id UUID NOT NULL REFERENCES public.journal_lines(id) ON DELETE CASCADE,
  tag_key TEXT NOT NULL,
  tag_value TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by TEXT
);

COMMENT ON TABLE public.transaction_tags IS 'Cross-cutting classification tags on journal lines. Use for dimensions that are not GL accounts: ghost_tithe, marketing_channel, budget_category assignment overrides, project attribution, etc. Multiple tags per journal line allowed.';

CREATE INDEX IF NOT EXISTS idx_transaction_tags_journal_line ON public.transaction_tags(journal_line_id);
CREATE INDEX IF NOT EXISTS idx_transaction_tags_key_value ON public.transaction_tags(agency_id, tag_key, tag_value);
CREATE INDEX IF NOT EXISTS idx_transaction_tags_key ON public.transaction_tags(agency_id, tag_key);
