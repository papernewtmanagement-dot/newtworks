
-- ============================================================
-- MIGRATION 026 — Core Principles Table
-- ------------------------------------------------------------
-- Stores foundational principles that govern Claude sessions
-- above all other learnings. Loaded BEFORE persistent_memory
-- in the session startup protocol.
--
-- Priority scale convention:
--   100 — meta-principles (Operating Philosophy, claude_directives)
--    90 — foundational principles within a domain
--    80 — domain operating rules
--    70 and below — specific rules
--
-- Domains are free text. Seed values: operating_philosophy,
-- sales, financial, systems, claude_directives, compliance, hiring.
--
-- Idempotent. Safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.core_principles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  domain text NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  summary text,
  priority integer NOT NULL DEFAULT 50,
  books_referenced jsonb NOT NULL DEFAULT '[]'::jsonb,
  version integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  source text NOT NULL DEFAULT 'claude_conversation',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_core_principles_agency_active_priority
  ON public.core_principles(agency_id, is_active, priority DESC);
CREATE INDEX IF NOT EXISTS idx_core_principles_domain
  ON public.core_principles(agency_id, domain);

ALTER TABLE public.core_principles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "core_principles_select" ON public.core_principles;
CREATE POLICY "core_principles_select" ON public.core_principles
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "core_principles_insert" ON public.core_principles;
CREATE POLICY "core_principles_insert" ON public.core_principles
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "core_principles_update" ON public.core_principles;
CREATE POLICY "core_principles_update" ON public.core_principles
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "core_principles_delete" ON public.core_principles;
CREATE POLICY "core_principles_delete" ON public.core_principles
  FOR DELETE TO anon, authenticated USING (true);

