-- The existing `target` column is one number; SF Scorecard has both a
-- minimum-to-qualify and a maximum-for-full-credit. Add both, keep target
-- around as a synonym for max_target.
ALTER TABLE public.scorecard_tracking
  ADD COLUMN IF NOT EXISTS min_target numeric,
  ADD COLUMN IF NOT EXISTS max_target numeric,
  ADD COLUMN IF NOT EXISTS as_of_date date;

COMMENT ON COLUMN public.scorecard_tracking.min_target IS 'Minimum to qualify for Scorecard credit on this metric';
COMMENT ON COLUMN public.scorecard_tracking.max_target IS 'Maximum / full-credit threshold on this metric';
COMMENT ON COLUMN public.scorecard_tracking.actual IS 'Current on-time pace (annualized projection from YTD)';
COMMENT ON COLUMN public.scorecard_tracking.as_of_date IS 'Date the actual was snapshotted';
