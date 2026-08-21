-- Migration 034: Add EUR (Underwriting Reports) per-person count to weekly_cpr_team_detail.
-- EUR = count of customers in the week who had 3+ underwriting reports run on a single LOB.
-- Per team member. Tracked but NOT included in personal_misses (does not feed Requirements
-- "This Wk" column). See get_weekly_cpr_requirements — personal_misses still counts only
-- cpr_reply_done / wrapup_done / inbox_done.

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS eur_count INTEGER;

COMMENT ON COLUMN public.weekly_cpr_team_detail.eur_count IS
  'EUR = Underwriting Reports. Count of customers in the week who had 3+ UW reports run on a single LOB. Per team member. Tracked but NOT counted against requirements (per Peter, 2026-06-27).';
