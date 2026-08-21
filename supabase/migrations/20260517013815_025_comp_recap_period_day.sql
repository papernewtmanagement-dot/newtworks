-- Add period_day to distinguish 1H vs 2H comp recaps and deduction statements
-- within the same month. Required because State Farm issues twice-monthly recaps
-- and the original unique key (agency, year, month, category, description) cannot
-- represent both halves of a month as separate rows.

ALTER TABLE comp_recap
  ADD COLUMN IF NOT EXISTS period_day INTEGER;

-- Drop the old too-narrow unique key
ALTER TABLE comp_recap
  DROP CONSTRAINT IF EXISTS comp_recap_agency_id_period_year_period_month_comp_category_key;

-- New unique key: now includes period_day. NULL period_day acts as a wildcard
-- because PG treats NULLs as distinct in unique constraints. To prevent that,
-- we use a unique INDEX with COALESCE so NULL == NULL for the purpose of dedup.
CREATE UNIQUE INDEX IF NOT EXISTS comp_recap_dedup_uidx
  ON comp_recap (
    agency_id,
    period_year,
    period_month,
    COALESCE(period_day, 0),
    comp_category,
    description
  );

COMMENT ON COLUMN comp_recap.period_day IS 'Day-of-month of the recap (e.g. day 12 for a 1-12 1H period, day 26 for 16-30 2H). Distinguishes twice-monthly SF comp/deduction documents.';
