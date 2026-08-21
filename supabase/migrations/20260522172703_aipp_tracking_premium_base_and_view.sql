-- AIPP tracking: store the PREMIUM BASE the payout is computed from
ALTER TABLE aipp_tracking
  ADD COLUMN IF NOT EXISTS qualifying_premium_ytd numeric;
ALTER TABLE aipp_tracking
  ADD COLUMN IF NOT EXISTS through_month integer;
ALTER TABLE aipp_tracking
  ADD COLUMN IF NOT EXISTS rate_used numeric DEFAULT 0.05;

CREATE UNIQUE INDEX IF NOT EXISTS uq_aipp_tracking_year
  ON aipp_tracking (agency_id, program_year);

-- ============================================================
-- LIVE AIPP PROJECTION VIEW
-- Reads producer_production (premium issued, new + AIPP-qualifying)
-- Computes: YTD qualifying premium, projected full-year premium
-- (straight-line through the latest month with data), and the
-- resulting 5% AIPP payout estimate for the FOLLOWING Jan 15.
-- ============================================================
CREATE OR REPLACE VIEW v_aipp_projection AS
WITH agency_cfg AS (
  SELECT id AS agency_id,
         COALESCE(aipp_rate, 0.05) AS aipp_rate
  FROM agency
),
qual AS (
  SELECT pp.agency_id,
         pp.period_year,
         SUM(pp.premium_issued)                       AS qualifying_premium_ytd,
         MAX(pp.period_month)                          AS through_month,
         COUNT(DISTINCT pp.period_month)               AS months_with_data
  FROM producer_production pp
  WHERE pp.is_aipp_qualifying = true
  GROUP BY pp.agency_id, pp.period_year
)
SELECT
  q.agency_id,
  q.period_year                                                   AS program_year,
  q.through_month,
  q.months_with_data,
  ROUND(q.qualifying_premium_ytd, 2)                              AS qualifying_premium_ytd,
  -- straight-line full-year projection based on months elapsed
  ROUND(q.qualifying_premium_ytd / NULLIF(q.through_month,0) * 12, 2)
                                                                  AS projected_full_year_premium,
  c.aipp_rate,
  ROUND(q.qualifying_premium_ytd * c.aipp_rate, 2)                AS aipp_earned_ytd,
  ROUND((q.qualifying_premium_ytd / NULLIF(q.through_month,0) * 12) * c.aipp_rate, 2)
                                                                  AS aipp_projected_payout,
  q.period_year + 1                                               AS payout_year,
  make_date(q.period_year + 1, 1, 15)                             AS projected_payout_date
FROM qual q
JOIN agency_cfg c ON c.agency_id = q.agency_id;
