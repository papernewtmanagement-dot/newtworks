-- Add business_entity_id column to team table, FK to business_entities
ALTER TABLE public.team
ADD COLUMN IF NOT EXISTS business_entity_id UUID REFERENCES public.business_entities(id);

CREATE INDEX IF NOT EXISTS idx_team_business_entity_id ON public.team(business_entity_id);

COMMENT ON COLUMN public.team.business_entity_id IS 'Which business entity the person works for (PaperNewt LLC or Peter Story State Farm). Use this for entity-scoped queries instead of agency_id.';
