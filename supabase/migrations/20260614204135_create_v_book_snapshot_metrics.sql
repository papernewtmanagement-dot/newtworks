CREATE OR REPLACE VIEW public.v_book_snapshot_metrics AS
WITH base AS (
  SELECT 
    bs.id, bs.agency_id, bs.snapshot_date, bs.cadence,
    bs.auto_pif, bs.fire_pif, bs.life_pif, bs.health_pif, bs.household_count,
    -- MTD production / lapse (entered weekly by Peter)
    bs.auto_production_mtd, bs.auto_lapse_mtd,
    bs.fire_production_mtd, bs.fire_lapse_mtd,
    bs.life_production_mtd, bs.life_lapse_mtd,
    -- MTD net gain (computed)
    COALESCE(bs.auto_production_mtd,0) - COALESCE(bs.auto_lapse_mtd,0) AS auto_gain_mtd,
    COALESCE(bs.fire_production_mtd,0) - COALESCE(bs.fire_lapse_mtd,0) AS fire_gain_mtd,
    COALESCE(bs.life_production_mtd,0) - COALESCE(bs.life_lapse_mtd,0) AS life_gain_mtd,
    -- LOB-per-HH distribution (counts stored, pct computed)
    bs.count_hh_1_lob, bs.count_hh_2_lob, bs.count_hh_3_lob,
    COALESCE(bs.count_hh_1_lob,0) + COALESCE(bs.count_hh_2_lob,0) + COALESCE(bs.count_hh_3_lob,0) AS total_hh_in_lob_dist,
    -- Operational metrics
    bs.dss_pct, bs.mld_pct,
    -- Calendar grain for "best in quarter" rollup
    EXTRACT(YEAR FROM bs.snapshot_date)::int AS yr,
    EXTRACT(QUARTER FROM bs.snapshot_date)::int AS qtr
  FROM public.book_snapshot bs
),
with_pct AS (
  SELECT *,
    CASE WHEN total_hh_in_lob_dist > 0 
      THEN ROUND(count_hh_1_lob::numeric / total_hh_in_lob_dist * 100, 2) END AS pct_hh_1_lob,
    CASE WHEN total_hh_in_lob_dist > 0 
      THEN ROUND(count_hh_2_lob::numeric / total_hh_in_lob_dist * 100, 2) END AS pct_hh_2_lob,
    CASE WHEN total_hh_in_lob_dist > 0 
      THEN ROUND(count_hh_3_lob::numeric / total_hh_in_lob_dist * 100, 2) END AS pct_hh_3_lob
  FROM base
),
quarter_bests AS (
  SELECT agency_id, yr, qtr,
    MIN(pct_hh_1_lob) AS best_pct_hh_1_lob,
    MAX(pct_hh_2_lob) AS best_pct_hh_2_lob,
    MAX(pct_hh_3_lob) AS best_pct_hh_3_lob,
    MAX(dss_pct) AS best_dss_pct,
    MAX(mld_pct) AS best_mld_pct
  FROM with_pct
  WHERE pct_hh_1_lob IS NOT NULL OR dss_pct IS NOT NULL OR mld_pct IS NOT NULL
  GROUP BY agency_id, yr, qtr
)
SELECT 
  w.*,
  qb.best_pct_hh_1_lob,
  qb.best_pct_hh_2_lob,
  qb.best_pct_hh_3_lob,
  qb.best_dss_pct,
  qb.best_mld_pct,
  -- Diff vs best in quarter (current minus best)
  CASE WHEN qb.best_pct_hh_2_lob IS NOT NULL 
    THEN w.pct_hh_2_lob - qb.best_pct_hh_2_lob END AS diff_pct_hh_2_lob_vs_best,
  CASE WHEN qb.best_pct_hh_3_lob IS NOT NULL 
    THEN w.pct_hh_3_lob - qb.best_pct_hh_3_lob END AS diff_pct_hh_3_lob_vs_best,
  CASE WHEN qb.best_dss_pct IS NOT NULL 
    THEN w.dss_pct - qb.best_dss_pct END AS diff_dss_vs_best,
  CASE WHEN qb.best_mld_pct IS NOT NULL 
    THEN w.mld_pct - qb.best_mld_pct END AS diff_mld_vs_best
FROM with_pct w
LEFT JOIN quarter_bests qb 
  ON qb.agency_id = w.agency_id 
  AND qb.yr = w.yr 
  AND qb.qtr = w.qtr;

COMMENT ON VIEW public.v_book_snapshot_metrics IS 
  'Computed metrics over book_snapshot: LOB-per-HH percentages (from counts), MTD gain (production minus lapse), best-in-quarter benchmarks, and diff vs best. For LOB 1, "best" = lowest pct (concentration in 1-LOB is the bad direction); for 2 and 3 LOB, "best" = highest pct.';

GRANT SELECT ON public.v_book_snapshot_metrics TO anon, authenticated;
