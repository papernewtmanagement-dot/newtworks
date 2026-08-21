-- ============================================================================
-- MIGRATION: Multi-business entity scoping (Phase 1)
-- Adds: business_entities table, scope_entity_ids column on core_principles
-- Seeds: PaperNewt LLC (root), Peter Story State Farm (under PaperNewt)
-- Scopes: existing 16 principles as universal or PSS-specific
-- ============================================================================

-- 1. business_entities table
CREATE TABLE IF NOT EXISTS public.business_entities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  name text NOT NULL,
  slug text NOT NULL,
  entity_type text NOT NULL CHECK (entity_type IN (
    'llc','sole_prop','s_corp','exploration','dormant','personal'
  )),
  parent_entity_id uuid REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active' CHECK (status IN (
    'active','exploring','dormant','wound_down'
  )),
  description text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_business_entities_parent ON public.business_entities(parent_entity_id);
CREATE INDEX IF NOT EXISTS idx_business_entities_agency ON public.business_entities(agency_id);

COMMENT ON TABLE public.business_entities IS
  'Sub-business entities under the PaperNewt umbrella. Hierarchical via parent_entity_id. The agency_id column matches the system-wide tenant convention.';

-- 2. Add scope_entity_ids to core_principles
ALTER TABLE public.core_principles
  ADD COLUMN IF NOT EXISTS scope_entity_ids uuid[] DEFAULT NULL;

COMMENT ON COLUMN public.core_principles.scope_entity_ids IS
  'Entity anchors for this principle. NULL/empty = universal (applies to all entities). Otherwise applies to each listed entity AND all descendants (inheritance model). Within a domain, more-specific anchor wins; ties broken by priority.';

-- 3. Seed PaperNewt (root) and PSS with stable UUIDs for referencing
INSERT INTO public.business_entities (
  id, agency_id, name, slug, entity_type, parent_entity_id, status, description
)
VALUES
  (
    'b1111111-1111-1111-1111-111111111111'::uuid,
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    'PaperNewt LLC',
    'papernewt',
    's_corp',
    NULL,
    'active',
    'Parent holding company. S-Corp employer of record (effective 01/01/2026) for the broader business operation.'
  ),
  (
    'b2222222-2222-2222-2222-222222222222'::uuid,
    '126794dd-25ff-47d2-a436-724499733365'::uuid,
    'Peter Story State Farm',
    'pss',
    'sole_prop',
    'b1111111-1111-1111-1111-111111111111'::uuid,
    'active',
    'State Farm insurance agency. Sole proprietorship under the SF agent appointment held by Peter (appointed 10/1/2018).'
  )
ON CONFLICT (agency_id, slug) DO NOTHING;

-- 4a. Universal principles (no scope — applies everywhere via NULL):
UPDATE public.core_principles
SET scope_entity_ids = NULL
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND domain IN (
    'scripture',
    'personal_boundaries',
    'operating_philosophy',
    'team',
    'team_compensation',
    'internal_communications',
    'vendors',
    'catastrophe_plan',
    'technology'
  );

-- 4b. PSS-only principles (anchored at Peter Story State Farm):
UPDATE public.core_principles
SET scope_entity_ids = ARRAY['b2222222-2222-2222-2222-222222222222'::uuid]
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND domain IN (
    'compliance',
    'compensation',
    'financial_health',
    'retention',
    'social_media_strategy',
    'marketing_and_leads'
  );
