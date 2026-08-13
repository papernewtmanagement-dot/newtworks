-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 15:28:58 UTC (ledger name: create_account_reclassifications_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730152858.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.account_reclassifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id UUID NOT NULL,
  from_account_id UUID NOT NULL REFERENCES public.chart_of_accounts(id),
  to_account_id UUID NOT NULL REFERENCES public.chart_of_accounts(id),
  filter_description TEXT NOT NULL,
  journal_line_count INT NOT NULL,
  total_amount NUMERIC(14,2) NOT NULL,
  performed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  performed_by TEXT,
  notes TEXT
);

COMMENT ON TABLE public.account_reclassifications IS 'Audit log of account reclassification events — batch moves of journal lines from one chart_of_accounts UUID to another. Every reclassification is captured here for reversibility and traceability.';

CREATE INDEX IF NOT EXISTS idx_account_reclassifications_from ON public.account_reclassifications(from_account_id);
CREATE INDEX IF NOT EXISTS idx_account_reclassifications_to ON public.account_reclassifications(to_account_id);
CREATE INDEX IF NOT EXISTS idx_account_reclassifications_agency_time ON public.account_reclassifications(agency_id, performed_at DESC);

-- Add traceability columns to journal_lines
ALTER TABLE public.journal_lines
  ADD COLUMN IF NOT EXISTS original_account_id UUID REFERENCES public.chart_of_accounts(id),
  ADD COLUMN IF NOT EXISTS reclassification_id UUID REFERENCES public.account_reclassifications(id);

COMMENT ON COLUMN public.journal_lines.original_account_id IS 'Set when a journal line has been reclassified — preserves the original account UUID for audit trail.';
COMMENT ON COLUMN public.journal_lines.reclassification_id IS 'FK to account_reclassifications record for the batch that moved this line.';
