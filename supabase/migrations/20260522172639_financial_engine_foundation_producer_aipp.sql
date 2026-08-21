-- ============================================================
-- FINANCIAL ENGINE FOUNDATION
-- Producer production + AIPP + ROI projection groundwork
-- Non-destructive: all additive (IF NOT EXISTS), no drops.
-- ============================================================

-- 1. EXTEND producer_production -----------------------------
-- premium_type distinguishes the AIPP driver (new) from renewal
ALTER TABLE producer_production
  ADD COLUMN IF NOT EXISTS premium_type text NOT NULL DEFAULT 'new';
ALTER TABLE producer_production
  ADD COLUMN IF NOT EXISTS is_aipp_qualifying boolean NOT NULL DEFAULT false;
ALTER TABLE producer_production
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'peter_manual';
ALTER TABLE producer_production
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Re-import safety: one row per producer/month/line/premium_type.
-- Lets us UPSERT (overwrite) instead of duplicating on re-entry.
CREATE UNIQUE INDEX IF NOT EXISTS uq_producer_production_grain
  ON producer_production
  (agency_id, staff_id, period_year, period_month, line_of_business, premium_type);

-- 2. STAFF pay frequency for correct annualization ----------
ALTER TABLE staff
  ADD COLUMN IF NOT EXISTS pay_frequency text DEFAULT 'weekly';

-- 3. AGENCY: AIPP rate config -------------------------------
ALTER TABLE agency
  ADD COLUMN IF NOT EXISTS aipp_rate numeric DEFAULT 0.05;
ALTER TABLE agency
  ADD COLUMN IF NOT EXISTS rates_are_defaults boolean DEFAULT true;
ALTER TABLE agency
  ADD COLUMN IF NOT EXISTS payroll_burden_multiplier numeric DEFAULT 1.15;

-- 4. SEED labeled placeholder rates (only if still NULL) -----
UPDATE agency
SET smvc_rate_pc        = COALESCE(smvc_rate_pc, 0.10),
    blended_rate_other  = COALESCE(blended_rate_other, 0.09),
    lapse_rate_annual   = COALESCE(lapse_rate_annual, 0.11),
    aipp_rate           = COALESCE(aipp_rate, 0.05),
    rates_are_defaults  = true,
    payroll_burden_multiplier = COALESCE(payroll_burden_multiplier, 1.15)
WHERE id = '126794dd-25ff-47d2-a436-724499733365';
