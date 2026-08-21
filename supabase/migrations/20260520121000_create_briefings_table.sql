CREATE TABLE IF NOT EXISTS briefings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL REFERENCES agency(id) ON DELETE CASCADE,
  briefing_date   date NOT NULL,
  sent_at         timestamptz,
  delivered       boolean DEFAULT false,
  opened          boolean DEFAULT false,
  recipient_email text,
  subject         text,
  body_markdown   text,
  body_html       text,
  kpis            jsonb,
  sections_included text[],
  created_at      timestamptz DEFAULT now(),
  UNIQUE (agency_id, briefing_date)
);

CREATE INDEX IF NOT EXISTS idx_briefings_agency_date
  ON briefings (agency_id, briefing_date DESC);

ALTER TABLE briefings ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON briefings TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON briefings TO authenticated;
GRANT ALL ON briefings TO service_role;
