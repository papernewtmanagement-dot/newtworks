-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 22:59:39 UTC (ledger name: create_sops_and_paper_newt_ventures) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701225939.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Two new tables: back-office SOPs + PaperNewt ventures (investment ideas, projects, courses, game IP)
CREATE TABLE IF NOT EXISTS public.sops (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  business_entity_id UUID,
  title TEXT NOT NULL,
  content TEXT,
  content_format TEXT NOT NULL DEFAULT 'markdown',
  source_url TEXT,
  source_confluence_page_id TEXT,
  owner TEXT,
  category TEXT,
  version INTEGER NOT NULL DEFAULT 1,
  is_active BOOLEAN NOT NULL DEFAULT true,
  archived_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sops_agency ON public.sops(agency_id);
CREATE INDEX IF NOT EXISTS idx_sops_category ON public.sops(category);
CREATE INDEX IF NOT EXISTS idx_sops_owner ON public.sops(owner);
CREATE INDEX IF NOT EXISTS idx_sops_is_active ON public.sops(is_active);

CREATE TABLE IF NOT EXISTS public.paper_newt_ventures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  business_entity_id UUID,
  title TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('investment_idea','project','course','game_ip','venture')),
  status TEXT NOT NULL DEFAULT 'idea' CHECK (status IN ('idea','exploring','planning','active','shelved','completed')),
  content TEXT,
  content_format TEXT NOT NULL DEFAULT 'markdown',
  source_url TEXT,
  source_page TEXT,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pnv_agency ON public.paper_newt_ventures(agency_id);
CREATE INDEX IF NOT EXISTS idx_pnv_business_entity ON public.paper_newt_ventures(business_entity_id);
CREATE INDEX IF NOT EXISTS idx_pnv_category ON public.paper_newt_ventures(category);
CREATE INDEX IF NOT EXISTS idx_pnv_status ON public.paper_newt_ventures(status);
CREATE INDEX IF NOT EXISTS idx_pnv_is_active ON public.paper_newt_ventures(is_active);
