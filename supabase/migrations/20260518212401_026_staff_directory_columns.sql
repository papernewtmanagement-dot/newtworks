-- Add columns the HRPeople StaffDirectory component expects.
-- These existed in MOCK_STAFF but never made it into the real schema.
-- Without them, the live data swap will crash on render.

ALTER TABLE staff ADD COLUMN IF NOT EXISTS licensed BOOLEAN DEFAULT false;
ALTER TABLE staff ADD COLUMN IF NOT EXISTS license_states TEXT[] DEFAULT '{}';
ALTER TABLE staff ADD COLUMN IF NOT EXISTS compliance_flag TEXT;

-- Backfill licensed=true for Producer / Account Manager / Owner roles
-- (these are the roles that typically carry an active SF license)
UPDATE staff
SET licensed = true
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND licensed = false
  AND (
    role ILIKE '%Producer%'
    OR role ILIKE '%Account Manager%'
    OR role ILIKE '%Owner%'
    OR role ILIKE '%LSP%'
    OR role ILIKE '%Financial Services%'
  );
