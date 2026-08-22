-- Consolidate sales_points_v2 into canonical sales_points column
-- Preserve old-system values in new sales_points_v01 column (versioned for future history layers)
-- Zero function/frontend rewiring — everything keeps calling sales_points

-- Step 1: new historical preservation column
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS sales_points_v01 numeric;

COMMENT ON COLUMN public.weekly_cpr_team_detail.sales_points_v01 IS
  'Pre-2026-07-11 sales_points values under prior activity-based scoring system. Preserved during rollout of new residual-pool comp. Naming (v01) allows future versioned historical columns.';

-- Step 2: preserve old-system sales_points into v01 (rows dated before rollout)
UPDATE public.weekly_cpr_team_detail wctd
  SET sales_points_v01 = sales_points
  WHERE sales_points IS NOT NULL
    AND weekly_cpr_report_id IN (
      SELECT id FROM public.weekly_cpr_reports
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND week_ending_date < '2026-07-11'::date
    );

-- Step 3: move sales_points_v2 into sales_points (canonical column)
-- Affects: 15 synthetic historical quarter-end rows (2023-2025) + 2026-06-27 real Q2 close row
UPDATE public.weekly_cpr_team_detail
  SET sales_points = sales_points_v2
  WHERE sales_points_v2 IS NOT NULL;

-- Step 4: clear historical CPR-era sales_points where no v2 backfill happened
-- Old-system values live in v01 now; canonical column stays NULL for those weeks
UPDATE public.weekly_cpr_team_detail
  SET sales_points = NULL
  WHERE sales_points_v2 IS NULL
    AND weekly_cpr_report_id IN (
      SELECT id FROM public.weekly_cpr_reports
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND week_ending_date < '2026-07-11'::date
    );

-- Step 5: drop the transitional v2 column (fully consolidated into sales_points now)
ALTER TABLE public.weekly_cpr_team_detail
  DROP COLUMN IF EXISTS sales_points_v2;

-- Step 6: update canonical column semantic comment
COMMENT ON COLUMN public.weekly_cpr_team_detail.sales_points IS
  'Canonical Sales Points under new comp structure (sf_builder_2026_07_07+). QTD cumulative for the quarter (each row = quarter-to-date SP through that Saturday). 1 SP = $1 team commission. Pre-2026-07-11 old-system values preserved in sales_points_v01.';
