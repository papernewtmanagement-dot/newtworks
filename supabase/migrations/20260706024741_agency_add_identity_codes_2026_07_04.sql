-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 02:47:41 UTC (ledger name: agency_add_identity_codes_2026_07_04) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706024741.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Add missing identifiers from the old checklist header.
-- state_farm_agent_code was holding the TXDI number by mistake ("TX-2277768");
-- correct value is "53-1BDD" per the retired Confluence checklist header.
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS txdi_number TEXT;
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS national_producer_number TEXT;
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS jackson_id TEXT;
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS customer_email TEXT;

COMMENT ON COLUMN public.agency.state_farm_agent_code IS 'SF State-Agent Code (e.g., 53-1BDD). Distinct from TXDI and NPN.';
COMMENT ON COLUMN public.agency.txdi_number IS 'Texas Department of Insurance license number for the principal agent.';
COMMENT ON COLUMN public.agency.national_producer_number IS 'NAIC National Producer Number (NPN) for the principal agent.';
COMMENT ON COLUMN public.agency.jackson_id IS 'Legacy SF Jackson ID (e.g., 212-1487 (1998)).';
COMMENT ON COLUMN public.agency.customer_email IS 'Customer-facing inbound email address (distinct from primary_email which is ops).';
