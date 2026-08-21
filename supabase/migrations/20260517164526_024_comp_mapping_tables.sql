-- =============================================================================
-- MIGRATION 024: comp_category_map + comp_deduction_map
-- =============================================================================
-- Two mapping tables that drive gl_entry_writer:
--   comp_category_map: comp_category (+ optional description regex) → legacy source revenue sub-account
--   comp_deduction_map: deduction comp_category (+ optional desc regex) → legacy source expense account
-- Priority order: more-specific (description_pattern populated) matches before generic.
-- Both editable any time without code changes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.comp_category_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  comp_category text NOT NULL,
  description_pattern text,
  source_account_name text NOT NULL,
  source_parent_account_name text NOT NULL DEFAULT '4005 State Farm',
  priority int NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT TRUE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comp_category_map_lookup 
  ON comp_category_map (agency_id, comp_category, priority);

CREATE TABLE IF NOT EXISTS public.comp_deduction_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  comp_category text NOT NULL,
  description_pattern text,
  source_account_name text NOT NULL,
  source_parent_account_name text NOT NULL,
  priority int NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT TRUE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comp_deduction_map_lookup
  ON comp_deduction_map (agency_id, comp_category, priority);

-- =============================================================================
-- Seed comp_category_map (revenue side)
-- =============================================================================

INSERT INTO public.comp_category_map 
  (agency_id, comp_category, description_pattern, source_account_name, priority, notes)
VALUES
  -- P&C: Auto + Fire = combined P&C in legacy source
  ('126794dd-25ff-47d2-a436-724499733365', 'auto_new', NULL, '01 - P&C - NEW', 100, 'Auto NEW → P&C NEW bucket'),
  ('126794dd-25ff-47d2-a436-724499733365', 'auto_renewal', NULL, '01 - P&C - RENEWAL', 100, 'Auto RENEWAL → P&C RENEWAL bucket'),
  ('126794dd-25ff-47d2-a436-724499733365', 'fire_new', NULL, '01 - P&C - NEW', 100, 'Fire NEW → P&C NEW bucket'),
  ('126794dd-25ff-47d2-a436-724499733365', 'fire_renewal', NULL, '01 - P&C - RENEWAL', 100, 'Fire RENEWAL → P&C RENEWAL bucket'),
  -- Life
  ('126794dd-25ff-47d2-a436-724499733365', 'life_new', NULL, '02 - LIFE - NEW', 100, NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'life_renewal', NULL, '02 - LIFE - RENEWAL', 100, NULL),
  -- Health
  ('126794dd-25ff-47d2-a436-724499733365', 'health_new', NULL, '04 - HEALTH - NEW', 100, NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'health_renewal', NULL, '04 - HEALTH - RENEWAL', 100, NULL),
  -- Pet
  ('126794dd-25ff-47d2-a436-724499733365', 'pet_new', NULL, '05 - PET INSURANCE - NEW', 100, NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'pet_renewal', NULL, '05 - PET INSURANCE - RENEWAL', 100, NULL),
  -- "other" catch-all needs description-pattern matching FIRST (lower priority number = higher precedence)
  -- LLOYDS / LLYD → P&C per Peter (surplus lines, mostly P&C-like)
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'LLOYDS.*NEW|LLYD.*NEW', '01 - P&C - NEW', 50, 'Lloyds new business = surplus lines, books to P&C NEW per Peter Session 14'),
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'LLOYDS.*RENEWAL|LLYD.*RENEWAL', '01 - P&C - RENEWAL', 50, 'Lloyds renewal = surplus lines, books to P&C RENEWAL per Peter Session 14'),
  -- IPSI LIFE
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'IPSI', '07 - IPSI LIFE', 50, 'IPSI LIFE ALLIANCE → 07 IPSI LIFE sub-account'),
  -- SFVC
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'SFVC|VEHICLE CARE', '06 - SFVC', 50, 'SF Vehicle Care'),
  -- US Bank related income
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'US BANK|USBANK', '03 - US BANK', 50, 'US Bank related comp'),
  -- SF Classic — flag as ambiguous, book to parent until Marie clarifies (gross-up still works, sub-account fix later)
  ('126794dd-25ff-47d2-a436-724499733365', 'other', 'SFCL|SF CLASSIC', '01 - P&C - NEW', 60, 'SF Classic new business — assumed P&C NEW. Flag for Marie review.'),
  -- Other "other" catch-all
  ('126794dd-25ff-47d2-a436-724499733365', 'other', NULL, '4005 State Farm', 200, 'Generic other → 4005 parent (safe fallback)');

-- =============================================================================
-- Seed comp_deduction_map (deduction side → expense accounts)
-- =============================================================================

INSERT INTO public.comp_deduction_map
  (agency_id, comp_category, description_pattern, source_account_name, source_parent_account_name, priority, notes)
VALUES
  -- Advertising / Marketing deductions
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_advertising', 'ECHO.*DIRECT MAIL', 'Direct Mail & Supplies', '0003 MARKETING 10% > 9% > 8%', 50, 'ECHO Co-op Direct Mail → Marketing/Direct Mail. Confirm with Marie if she uses different sub.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_advertising', NULL, 'Promotional Materials', '0003 MARKETING 10% > 9% > 8%', 100, 'Generic advertising deduction → Marketing/Promotional Materials'),
  -- Technology deductions
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_technology', 'AGENT EQUIPMENT LEASE', 'Equipment Purchases', '0001 ADMINISTRATION 6% > 5%> 5%', 50, 'SF agent equipment lease → Admin/Equipment Purchases'),
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_technology', 'MYSFDOMAIN|MY SF DOMAIN', 'Internet', '0001 ADMINISTRATION 6% > 5%> 5%', 50, 'MySFDomain web services → Admin/Internet'),
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_technology', NULL, 'Computer', '0001 ADMINISTRATION 6% > 5%> 5%', 100, 'Generic tech deduction → Admin/Computer'),
  -- License / appointment fees
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_license', 'AGENT STAFF|TEAM', 'Dues & Licenses - TEAM', '0002 TEAM 55% > 54%> 50%', 50, 'Staff appointment fees → Team dues & licenses'),
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_license', NULL, 'Dues & Licenses - AGENT', '0001 ADMINISTRATION 6% > 5%> 5%', 100, 'Generic license fee → Admin/Agent dues'),
  -- Office supplies
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_supplies', NULL, 'Office Supplies', '0001 ADMINISTRATION 6% > 5%> 5%', 100, NULL),
  -- E&O / professional insurance deductions
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_eo', NULL, 'Errors & Omissions', '0001 ADMINISTRATION 6% > 5%> 5%', 100, 'E&O premium deductions'),
  -- Training
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_training', NULL, 'Training, Seminars - AGENT', '0001 ADMINISTRATION 6% > 5%> 5%', 100, NULL),
  -- Subscriptions / books
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_subscription', NULL, 'Books, Subscriptions etc', '0001 ADMINISTRATION 6% > 5%> 5%', 100, NULL),
  -- Misc / catch-all
  ('126794dd-25ff-47d2-a436-724499733365', 'deduction_misc', NULL, 'Miscellaneous', '0001 ADMINISTRATION 6% > 5%> 5%', 100, 'Generic deduction catch-all');

SELECT 
  (SELECT COUNT(*) FROM comp_category_map WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365') as revenue_mappings,
  (SELECT COUNT(*) FROM comp_deduction_map WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365') as deduction_mappings;
