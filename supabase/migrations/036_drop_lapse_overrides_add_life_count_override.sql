-- Migration 036:
-- Per Peter (2026-06-27): lapse rate is always computed at runtime via compute_lapse_rate;
-- never store it. Drop the 3 manual override columns added in migration 033.
-- Also: make Life # YTD (life_paid_for_count_ytd) editable like the others.
-- See operational_rule "Lapse rate — never store, compute at runtime".

ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS auto_lapse_pct_manual;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS fire_lapse_pct_manual;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS life_lapse_pct_manual;

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS life_paid_for_count_ytd_manual INTEGER;

COMMENT ON COLUMN public.weekly_cpr_reports.life_paid_for_count_ytd_manual IS
  'Manual override for agency_snapshot.life_paid_for_count_ytd (Life # YTD). NULL = use snapshot. Same pattern as auto_new_ytd_manual et al.';
