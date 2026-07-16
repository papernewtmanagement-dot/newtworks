-- Migration: prior_year_pl pipeline (step 4 of 2026-07-15 handoff plan)
-- Purpose: ingest historical monthly P&L from Marie's QBO exports (2024 and earlier, 2025 full year, 2026 YTD through 6/30)
-- No JEs generated — this is prior-period reporting/benchmarking only. Cutover excision (2026-07-15) already removed pre-7/1 JEs.

CREATE TABLE IF NOT EXISTS public.prior_year_pl (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::UUID
    REFERENCES public.agency(id),
  business_entity_id UUID NOT NULL DEFAULT 'b1111111-1111-1111-1111-111111111111'::UUID
    REFERENCES public.business_entities(id),

  -- Period
  period_year INT NOT NULL CHECK (period_year BETWEEN 2020 AND 2026),
  period_month INT NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  period_start DATE GENERATED ALWAYS AS (make_date(period_year, period_month, 1)) STORED,
  period_end DATE GENERATED ALWAYS AS
    ((make_date(period_year, period_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')::DATE) STORED,
  is_partial_period BOOLEAN NOT NULL DEFAULT FALSE,
  period_actual_end_date DATE,

  -- Account (QBO verbatim)
  section TEXT NOT NULL,
  section_type TEXT NOT NULL
    CHECK (section_type IN ('Income','Expense','Other Income','Other Expense')),
  account_name TEXT NOT NULL,
  amount NUMERIC(14,2) NOT NULL,

  -- Provenance
  source_entity TEXT,
  source_document_id UUID REFERENCES public.documents(id),
  imported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT prior_year_pl_uniq
    UNIQUE (agency_id, business_entity_id, period_year, period_month, section, account_name)
);

CREATE INDEX IF NOT EXISTS idx_prior_year_pl_period
  ON public.prior_year_pl (agency_id, business_entity_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS idx_prior_year_pl_section
  ON public.prior_year_pl (agency_id, business_entity_id, section, section_type);

ALTER TABLE public.prior_year_pl ENABLE ROW LEVEL SECURITY;

CREATE POLICY prior_year_pl_admin_select ON public.prior_year_pl
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  );

COMMENT ON TABLE public.prior_year_pl IS
  'Monthly P&L from prior-books QBO exports (pre-2026-07-01 cutover). Ingested via document-processor. No journal_entries generated. Consumers: Financials P&L view (prior-period comparison) + variance benchmarking.';


CREATE TABLE IF NOT EXISTS public.prior_year_pl_account_map (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::UUID
    REFERENCES public.agency(id),
  qbo_section TEXT NOT NULL,
  qbo_account_name TEXT NOT NULL,
  newtworks_account_code TEXT,
  newtworks_envelope TEXT,
  notes TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, qbo_section, qbo_account_name)
);

ALTER TABLE public.prior_year_pl_account_map ENABLE ROW LEVEL SECURITY;

CREATE POLICY pypam_admin_select ON public.prior_year_pl_account_map
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  );

CREATE POLICY pypam_admin_write ON public.prior_year_pl_account_map
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  );

COMMENT ON TABLE public.prior_year_pl_account_map IS
  'Crosswalk from QBO account names (in prior_year_pl) to Newtworks chart_of_accounts. Built incrementally — unmapped rows are OK.';
