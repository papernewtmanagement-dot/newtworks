-- Book growth targets — Peter Story State Farm
-- One row per (agency, year). Targets are for year-end positions and YTD flow metrics.
-- No AIPP linkage: this table stands alone and does not reference any AIPP schema.

CREATE TABLE IF NOT EXISTS public.book_growth_targets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  target_year INTEGER NOT NULL,

  -- Year-end book size targets
  auto_premium_target       NUMERIC,
  fire_premium_target       NUMERIC,
  life_premium_target       NUMERIC,
  household_count_target    INTEGER,

  -- YTD flow targets (annual, measured against agency_snapshot YTD columns)
  auto_items_net_target        INTEGER,
  fire_items_net_target        INTEGER,
  life_items_target            INTEGER,
  life_paid_for_count_target   INTEGER,
  ips_new_money_target         NUMERIC,

  notes      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT book_growth_targets_agency_year_unique UNIQUE (agency_id, target_year)
);

CREATE INDEX IF NOT EXISTS book_growth_targets_agency_year_idx
  ON public.book_growth_targets (agency_id, target_year DESC);

ALTER TABLE public.book_growth_targets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "book_growth_targets_all" ON public.book_growth_targets;
CREATE POLICY "book_growth_targets_all"
  ON public.book_growth_targets
  FOR ALL
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.book_growth_targets IS
  'Annual book growth targets. No AIPP linkage — targets set independently of any compensation program. Book/Goals tab in Newtworks reads/writes this table.';
