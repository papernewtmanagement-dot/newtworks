CREATE TABLE IF NOT EXISTS monthly_close_checklist (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID NOT NULL REFERENCES agency(id) ON DELETE CASCADE,
  period_year     INTEGER NOT NULL,
  period_month    INTEGER NOT NULL,
  doc_category    TEXT NOT NULL,
  doc_label       TEXT NOT NULL,
  expected_by     DATE,
  received_at     DATE,
  document_id     UUID REFERENCES documents(id) ON DELETE SET NULL,
  status          TEXT NOT NULL DEFAULT 'expected',
  is_closed       BOOLEAN NOT NULL DEFAULT FALSE,
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_monthly_close_period
  ON monthly_close_checklist(agency_id, period_year, period_month);

ALTER TABLE monthly_close_checklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_monthly_close_checklist ON monthly_close_checklist;
CREATE POLICY anon_read_monthly_close_checklist
  ON monthly_close_checklist
  FOR SELECT TO anon USING (true);

GRANT SELECT ON monthly_close_checklist TO anon;
