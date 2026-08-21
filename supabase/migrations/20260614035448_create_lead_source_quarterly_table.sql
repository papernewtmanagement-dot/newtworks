-- Lead source quarterly: weekly-cadence snapshots of quarter-to-date "Won" data by source
-- from the State Farm CRM Analytics widget subscription. Captured for trend analysis;
-- no automation hangs off it yet.
--
-- Each weekly snapshot records the Q-to-date count and dollars Won by source as of that date.
-- Numbers grow within a quarter, reset when the next quarter begins.

CREATE TABLE IF NOT EXISTS public.lead_source_quarterly (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           uuid NOT NULL REFERENCES public.agency(id),
  snapshot_date       date NOT NULL,          -- "as of" date from the source email
  period_year         integer NOT NULL,
  period_quarter      integer NOT NULL CHECK (period_quarter BETWEEN 1 AND 4),
  source              text NOT NULL,          -- Referral, SF.com, EverQuote, QuoteWizard, MediaAlpha, etc.
  won_households      integer,
  won_premium         numeric(14,2),
  source_document_id  uuid REFERENCES public.documents(id),
  notes               text,
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),
  UNIQUE (agency_id, snapshot_date, period_year, period_quarter, source)
);

CREATE INDEX IF NOT EXISTS idx_lead_source_quarterly_period
  ON public.lead_source_quarterly (agency_id, period_year, period_quarter, snapshot_date DESC);

CREATE INDEX IF NOT EXISTS idx_lead_source_quarterly_source
  ON public.lead_source_quarterly (agency_id, source, snapshot_date DESC);

ALTER TABLE public.lead_source_quarterly ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "lsq_select_all" ON public.lead_source_quarterly;
CREATE POLICY "lsq_select_all" ON public.lead_source_quarterly
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "lsq_insert_all" ON public.lead_source_quarterly;
CREATE POLICY "lsq_insert_all" ON public.lead_source_quarterly
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "lsq_update_all" ON public.lead_source_quarterly;
CREATE POLICY "lsq_update_all" ON public.lead_source_quarterly
  FOR UPDATE TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "lsq_delete_all" ON public.lead_source_quarterly;
CREATE POLICY "lsq_delete_all" ON public.lead_source_quarterly
  FOR DELETE TO anon, authenticated USING (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.lead_source_quarterly TO anon, authenticated;

COMMENT ON TABLE public.lead_source_quarterly IS 'Weekly snapshots of quarter-to-date Won-HH and Won-$ by lead source from SF CRM Analytics widget subscription. Stock-of-flow data: each row is Q-to-date as of snapshot_date.';
