-- ============================================================================
-- Migration: cpr_ytd_drop_manual_shadow_columns
-- Applied: 2026-07-07 00:37:07 UTC (Supabase)
-- ============================================================================
-- Drops the 8 _manual shadow columns from weekly_cpr_reports. Values were
-- backfilled into agency_snapshot in the earlier backfill migration. All
-- consumers (compose_weekly_cpr_html, get_cpr_section_11, compute_scorecard_bonus,
-- CPRDetail.jsx) now read/write agency_snapshot as source of truth.

ALTER TABLE public.weekly_cpr_reports
  DROP COLUMN IF EXISTS auto_new_ytd_manual,
  DROP COLUMN IF EXISTS auto_lost_ytd_manual,
  DROP COLUMN IF EXISTS fire_new_ytd_manual,
  DROP COLUMN IF EXISTS fire_lost_ytd_manual,
  DROP COLUMN IF EXISTS life_new_ytd_manual,
  DROP COLUMN IF EXISTS life_lost_ytd_manual,
  DROP COLUMN IF EXISTS life_paid_for_count_ytd_manual,
  DROP COLUMN IF EXISTS life_paid_for_premium_ytd_manual;
