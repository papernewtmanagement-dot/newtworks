-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 15:26:42 UTC (ledger name: create_account_master_codes_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730152642.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.account_master_codes (
  agency_id UUID NOT NULL,
  code CHAR(4) NOT NULL,
  name TEXT NOT NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('asset','liability','equity','income','expense')),
  account_subtype TEXT,
  code_kind TEXT NOT NULL CHECK (code_kind IN ('shared_concept','entity_specific')),
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, code)
);

COMMENT ON TABLE public.account_master_codes IS 'Master list of 4-digit account codes defining conceptual meaning. chart_of_accounts references this via (agency_id, account_code). shared_concept = universal meaning across entities; entity_specific = tied to a specific real-world account (bank, credit card, subsidiary investment).';

CREATE INDEX IF NOT EXISTS idx_account_master_codes_type ON public.account_master_codes(agency_id, account_type);
CREATE INDEX IF NOT EXISTS idx_account_master_codes_kind ON public.account_master_codes(agency_id, code_kind);
