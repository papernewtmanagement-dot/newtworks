-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-13 18:45:54 UTC (ledger name: create_hiregauge_rules_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260713184554.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- HireGauge rules table: structured storage for framework rules that can be
-- applied programmatically to future candidate assessments.

CREATE TABLE IF NOT EXISTS public.hiregauge_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',

  -- Categorization
  rule_type TEXT NOT NULL CHECK (rule_type IN (
    'archetype', 'coaching_variant', 'money_motivator', 'diagnostic_tool',
    'filter_rule', 'exit_mode', 'recommendation_logic', 'framework_principle',
    'behavioral_tell', 'reader_vulnerability', 'strategic_seat_pattern',
    'character_floor', 'validity_rule', 'drive_test'
  )),
  rule_name TEXT NOT NULL,
  short_label TEXT,

  -- Trait signature (machine-readable pattern for auto-matching)
  -- Format: {"logic": "all"|"any", "trait_conditions": [{"trait": "...", "op": "gte|lte|eq|between", "value": N, "value2": N (for between)}], "additional_conditions": {...}}
  trait_signature JSONB,
  trait_signature_readable TEXT,

  -- Applicable hiring stage (multi-value)
  hiring_stage TEXT[] DEFAULT ARRAY[]::TEXT[],

  -- Rule content (human-readable)
  description TEXT NOT NULL,
  diagnostic_action TEXT,
  recommendation TEXT,
  coaching_prescription TEXT,
  interview_probe TEXT,

  -- Calibration state
  calibration_status TEXT NOT NULL CHECK (calibration_status IN (
    'proposed', 'emerging_n1', 'watched_n2', 'calibrated_n3plus',
    'framework_principle', 'retired'
  )),
  supporting_candidates JSONB DEFAULT '[]'::jsonb,
  n_count INT DEFAULT 1,

  -- Validation
  real_world_validated BOOLEAN DEFAULT FALSE,
  validation_notes TEXT,

  -- Related rules
  related_rules UUID[] DEFAULT ARRAY[]::UUID[],
  supersedes UUID REFERENCES public.hiregauge_rules(id),
  superseded_by UUID REFERENCES public.hiregauge_rules(id),

  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  is_active BOOLEAN DEFAULT TRUE,
  notes TEXT
);

CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_type ON public.hiregauge_rules(rule_type);
CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_status ON public.hiregauge_rules(calibration_status);
CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_stage ON public.hiregauge_rules USING GIN(hiring_stage);
CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_agency ON public.hiregauge_rules(agency_id);
CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_active ON public.hiregauge_rules(agency_id, is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_hiregauge_rules_trait_sig ON public.hiregauge_rules USING GIN(trait_signature);

-- RLS
ALTER TABLE public.hiregauge_rules ENABLE ROW LEVEL SECURITY;

CREATE POLICY "hiregauge_rules_authenticated_agency_scope" ON public.hiregauge_rules
  FOR ALL
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "hiregauge_rules_service_role_all" ON public.hiregauge_rules
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.hiregauge_rules IS 'HireGauge framework rules for programmatic candidate assessment. Companion to team_assessments table.';
COMMENT ON COLUMN public.hiregauge_rules.trait_signature IS 'JSONB pattern: {"logic": "all"|"any", "trait_conditions": [{"trait": name, "op": comparison, "value": N, "value2": N}], "additional_conditions": {...}}';
