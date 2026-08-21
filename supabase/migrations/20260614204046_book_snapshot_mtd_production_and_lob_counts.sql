-- Replace per-week new/lost (wrong grain) with month-to-date production + lapse/can
-- Replace percent-stored LOB distribution with COUNT-stored (percentages computed in views)

ALTER TABLE public.book_snapshot
  DROP COLUMN IF EXISTS auto_new,
  DROP COLUMN IF EXISTS auto_lost,
  DROP COLUMN IF EXISTS fire_new,
  DROP COLUMN IF EXISTS fire_lost,
  DROP COLUMN IF EXISTS life_new,
  DROP COLUMN IF EXISTS life_lost,
  DROP COLUMN IF EXISTS health_new,
  DROP COLUMN IF EXISTS health_lost,
  DROP COLUMN IF EXISTS pct_hh_1_lob,
  DROP COLUMN IF EXISTS pct_hh_2_lob,
  DROP COLUMN IF EXISTS pct_hh_3_lob;

ALTER TABLE public.book_snapshot
  ADD COLUMN IF NOT EXISTS auto_production_mtd int,
  ADD COLUMN IF NOT EXISTS auto_lapse_mtd int,
  ADD COLUMN IF NOT EXISTS fire_production_mtd int,
  ADD COLUMN IF NOT EXISTS fire_lapse_mtd int,
  ADD COLUMN IF NOT EXISTS life_production_mtd int,
  ADD COLUMN IF NOT EXISTS life_lapse_mtd int,
  ADD COLUMN IF NOT EXISTS count_hh_1_lob int,
  ADD COLUMN IF NOT EXISTS count_hh_2_lob int,
  ADD COLUMN IF NOT EXISTS count_hh_3_lob int;

COMMENT ON COLUMN public.book_snapshot.auto_production_mtd IS 'Month-to-date new auto policies bound (entered weekly by Peter from CPR form, snapshots monthly progress)';
COMMENT ON COLUMN public.book_snapshot.auto_lapse_mtd IS 'Month-to-date auto policies lapsed/cancelled (entered weekly)';
COMMENT ON COLUMN public.book_snapshot.count_hh_1_lob IS 'Count of households with exactly 1 line of business. Percentage computed at view time.';
COMMENT ON COLUMN public.book_snapshot.count_hh_2_lob IS 'Count of households with exactly 2 lines of business';
COMMENT ON COLUMN public.book_snapshot.count_hh_3_lob IS 'Count of households with 3+ lines of business';
