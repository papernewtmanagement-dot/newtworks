-- Drops aipp_tracking. Table stored "current AIPP target / earned_ytd / projected_full_year"
-- which violates core_principle #650 (compensation_data_freshness) — these values must be
-- computed at runtime from comp_recap, not stored. Table was empty (0 rows) at drop time.
-- Replacement: a future compute_aipp_progress() function reading from comp_recap.
DROP TABLE IF EXISTS public.aipp_tracking;
