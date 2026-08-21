ALTER TABLE agency
  ADD COLUMN IF NOT EXISTS smvc_rate_pc       NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS blended_rate_other NUMERIC(5,2),
  ADD COLUMN IF NOT EXISTS lapse_rate_annual  NUMERIC(5,2);

CREATE TABLE IF NOT EXISTS producer_production (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID NOT NULL REFERENCES agency(id) ON DELETE CASCADE,
  staff_id        UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  period_year     INTEGER NOT NULL,
  period_month    INTEGER NOT NULL,
  line_of_business TEXT NOT NULL,
  policies_issued INTEGER NOT NULL DEFAULT 0,
  premium_issued  NUMERIC(12,2) NOT NULL DEFAULT 0,
  source_document_id UUID,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, staff_id, period_year, period_month, line_of_business)
);

CREATE INDEX IF NOT EXISTS idx_producer_production_period
  ON producer_production(agency_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS idx_producer_production_staff
  ON producer_production(staff_id, period_year, period_month);

ALTER TABLE producer_production ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_producer_production ON producer_production;
CREATE POLICY anon_read_producer_production ON producer_production
  FOR SELECT TO anon USING (true);

GRANT SELECT ON producer_production TO anon;
