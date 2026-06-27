-- Migration 037: Make Life $ YTD (life_paid_for_premium_ytd) manually overridable.
-- Same pattern as auto_new_ytd_manual et al. NULL = use snapshot.

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS life_paid_for_premium_ytd_manual NUMERIC;

COMMENT ON COLUMN public.weekly_cpr_reports.life_paid_for_premium_ytd_manual IS
  'Manual override for agency_snapshot.life_paid_for_premium_ytd (Life $ YTD). NULL = use snapshot. Same pattern as auto_new_ytd_manual et al.';
