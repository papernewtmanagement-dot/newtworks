-- Snapshot table for the alphabet-based service book split.
-- One row per (agency, snapshot_date, letter_bucket). Letter buckets can be
-- single letters (A, B, ...) or combined buckets (X-Z, A-K, etc.) — the column
-- is free text so future re-bucketing doesn't require schema changes.

CREATE TABLE IF NOT EXISTS public.book_alpha_split (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  snapshot_date date NOT NULL,
  letter_bucket text NOT NULL,
  team_member_id uuid REFERENCES public.team(id) ON DELETE SET NULL,
  account_count integer NOT NULL DEFAULT 0 CHECK (account_count >= 0),
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (agency_id, snapshot_date, letter_bucket)
);

-- Indexes for typical query patterns
CREATE INDEX IF NOT EXISTS idx_book_alpha_split_agency_date
  ON public.book_alpha_split (agency_id, snapshot_date DESC);

CREATE INDEX IF NOT EXISTS idx_book_alpha_split_team_member
  ON public.book_alpha_split (agency_id, team_member_id, snapshot_date DESC);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.touch_book_alpha_split_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_book_alpha_split_updated_at ON public.book_alpha_split;
CREATE TRIGGER trg_book_alpha_split_updated_at
  BEFORE UPDATE ON public.book_alpha_split
  FOR EACH ROW EXECUTE FUNCTION public.touch_book_alpha_split_updated_at();

-- RLS: enable + grant to anon and authenticated (per coding rule 6)
ALTER TABLE public.book_alpha_split ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS book_alpha_split_all_anon ON public.book_alpha_split;
CREATE POLICY book_alpha_split_all_anon ON public.book_alpha_split
  FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS book_alpha_split_all_authenticated ON public.book_alpha_split;
CREATE POLICY book_alpha_split_all_authenticated ON public.book_alpha_split
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT ALL ON public.book_alpha_split TO anon, authenticated;

-- Convenience view: latest snapshot date + roll-up by team member
CREATE OR REPLACE VIEW public.v_book_alpha_split_latest AS
WITH latest AS (
  SELECT agency_id, MAX(snapshot_date) AS snapshot_date
  FROM public.book_alpha_split
  GROUP BY agency_id
)
SELECT
  bas.agency_id,
  bas.snapshot_date,
  bas.letter_bucket,
  bas.team_member_id,
  t.first_name,
  t.last_name,
  t.nickname,
  bas.account_count,
  bas.notes
FROM public.book_alpha_split bas
JOIN latest l ON l.agency_id = bas.agency_id AND l.snapshot_date = bas.snapshot_date
LEFT JOIN public.team t ON t.id = bas.team_member_id
ORDER BY bas.letter_bucket;

GRANT SELECT ON public.v_book_alpha_split_latest TO anon, authenticated;
