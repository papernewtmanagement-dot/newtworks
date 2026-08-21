-- Book of Business snapshot table
-- Captures point-in-time in-force premium by LOB, PIF by LOB, and household count.
-- Monthly historical from PDF (Oct 2018 - Jun 2026), weekly going forward.
-- Derived metrics (% change MoM, YoY, cumulative) live in views, not stored columns.

CREATE TABLE IF NOT EXISTS public.book_snapshot (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           uuid NOT NULL REFERENCES public.agency(id),
  snapshot_date       date NOT NULL,
  cadence             text NOT NULL CHECK (cadence IN ('weekly','monthly')),

  -- In-force premium by LOB ($)
  auto_premium        numeric(14,2),
  fire_premium        numeric(14,2),
  life_premium        numeric(14,2),
  health_premium      numeric(14,2),

  -- Policies-in-force by LOB (counts)
  auto_pif            integer,
  fire_pif            integer,
  life_pif            integer,
  health_pif          integer,

  -- Household count
  household_count     integer,

  -- Provenance
  source              text NOT NULL,
  source_document_id  uuid REFERENCES public.documents(id),
  notes               text,
  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now(),

  UNIQUE (agency_id, snapshot_date, cadence)
);

CREATE INDEX IF NOT EXISTS idx_book_snapshot_agency_date
  ON public.book_snapshot (agency_id, snapshot_date DESC);

CREATE INDEX IF NOT EXISTS idx_book_snapshot_cadence
  ON public.book_snapshot (cadence, snapshot_date DESC);

-- RLS — cover both anon and authenticated (per operating rule re: blank screens)
ALTER TABLE public.book_snapshot ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "book_snapshot_select_all" ON public.book_snapshot;
CREATE POLICY "book_snapshot_select_all" ON public.book_snapshot
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "book_snapshot_insert_all" ON public.book_snapshot;
CREATE POLICY "book_snapshot_insert_all" ON public.book_snapshot
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "book_snapshot_update_all" ON public.book_snapshot;
CREATE POLICY "book_snapshot_update_all" ON public.book_snapshot
  FOR UPDATE TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "book_snapshot_delete_all" ON public.book_snapshot;
CREATE POLICY "book_snapshot_delete_all" ON public.book_snapshot
  FOR DELETE TO anon, authenticated USING (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.book_snapshot TO anon, authenticated;

COMMENT ON TABLE public.book_snapshot IS 'Point-in-time snapshot of book of business: in-force premium by LOB, PIF counts by LOB, household count. Monthly historical + weekly going-forward. Derived % change metrics live in v_book_snapshot_with_changes view, not stored.';
