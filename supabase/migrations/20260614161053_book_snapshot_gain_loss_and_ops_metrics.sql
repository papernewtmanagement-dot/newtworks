-- Gain/loss flow columns per LOB (monthly flow that produces the end-of-period PIF)
ALTER TABLE public.book_snapshot
  ADD COLUMN IF NOT EXISTS auto_new int,
  ADD COLUMN IF NOT EXISTS auto_lost int,
  ADD COLUMN IF NOT EXISTS fire_new int,
  ADD COLUMN IF NOT EXISTS fire_lost int,
  ADD COLUMN IF NOT EXISTS life_new int,
  ADD COLUMN IF NOT EXISTS life_lost int,
  ADD COLUMN IF NOT EXISTS health_new int,
  ADD COLUMN IF NOT EXISTS health_lost int;

-- Operational quoting/saturation metrics (CPR sheet)
ALTER TABLE public.book_snapshot
  ADD COLUMN IF NOT EXISTS dss_pct numeric(5,4),
  ADD COLUMN IF NOT EXISTS mld_pct numeric(5,4),
  ADD COLUMN IF NOT EXISTS pct_hh_1_lob numeric(5,4),
  ADD COLUMN IF NOT EXISTS pct_hh_2_lob numeric(5,4),
  ADD COLUMN IF NOT EXISTS pct_hh_3_lob numeric(5,4);

-- Comments to be explicit about meaning
COMMENT ON COLUMN public.book_snapshot.auto_new IS 'New auto policies bound during the period';
COMMENT ON COLUMN public.book_snapshot.auto_lost IS 'Auto policies lost (cancelled/non-renewed) during the period';
COMMENT ON COLUMN public.book_snapshot.dss_pct IS 'DocuSign Send compliance rate (decimal, e.g. 0.82 = 82%)';
COMMENT ON COLUMN public.book_snapshot.mld_pct IS 'Mid-Lead Disposition rate (decimal, e.g. 0.64 = 64%)';
COMMENT ON COLUMN public.book_snapshot.pct_hh_1_lob IS 'Share of households with exactly 1 LOB (decimal, sums with 2/3 LOB = 100%)';
