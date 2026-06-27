-- Migration 033: Manual override fields on weekly_cpr_reports for Agency Performance section.
-- Snapshot auto-fill remains primary; manual values win when set (NULL = use snapshot).
-- Solves recurring partial-snapshot pain (e.g. 6/20 row where YTD inputs came in NULL while *_pif/*_premium were populated).
-- Also lets Peter manually enter lapse % per LOB when the runtime compute_lapse_rate output needs override.

ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS auto_new_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS auto_lost_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS fire_new_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS fire_lost_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS life_new_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS life_lost_ytd_manual INTEGER;
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS auto_lapse_pct_manual NUMERIC(5,2);
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS fire_lapse_pct_manual NUMERIC(5,2);
ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS life_lapse_pct_manual NUMERIC(5,2);

COMMENT ON COLUMN public.weekly_cpr_reports.auto_new_ytd_manual  IS 'Manual override for agency_snapshot.auto_new_ytd. NULL = use snapshot. Set via CPR Detail edit mode.';
COMMENT ON COLUMN public.weekly_cpr_reports.auto_lost_ytd_manual IS 'Manual override for agency_snapshot.auto_lost_ytd. NULL = use snapshot.';
COMMENT ON COLUMN public.weekly_cpr_reports.fire_new_ytd_manual  IS 'Manual override for agency_snapshot.fire_new_ytd. NULL = use snapshot.';
COMMENT ON COLUMN public.weekly_cpr_reports.fire_lost_ytd_manual IS 'Manual override for agency_snapshot.fire_lost_ytd. NULL = use snapshot.';
COMMENT ON COLUMN public.weekly_cpr_reports.life_new_ytd_manual  IS 'Manual override for agency_snapshot.life_new_ytd. NULL = use snapshot.';
COMMENT ON COLUMN public.weekly_cpr_reports.life_lost_ytd_manual IS 'Manual override for agency_snapshot.life_lost_ytd. NULL = use snapshot.';
COMMENT ON COLUMN public.weekly_cpr_reports.auto_lapse_pct_manual IS 'Manual override for compute_lapse_rate(auto). Whole-percent value (e.g. 8.5 = 8.5%). NULL = use computed.';
COMMENT ON COLUMN public.weekly_cpr_reports.fire_lapse_pct_manual IS 'Manual override for compute_lapse_rate(fire). NULL = use computed.';
COMMENT ON COLUMN public.weekly_cpr_reports.life_lapse_pct_manual IS 'Manual override for compute_lapse_rate(life). NULL = use computed.';
