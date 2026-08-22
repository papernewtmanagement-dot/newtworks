-- Drop 8 shadow columns from weekly_cpr_reports. Values already backfilled into
-- agency_snapshot; all consumers (compose_weekly_cpr_html, get_cpr_section_11,
-- compute_scorecard_bonus, CPRDetail.jsx) read from agency_snapshot. Zero remaining
-- references in DB objects or repo.

ALTER TABLE public.weekly_cpr_reports
  DROP COLUMN IF EXISTS auto_new_ytd_manual,
  DROP COLUMN IF EXISTS auto_lost_ytd_manual,
  DROP COLUMN IF EXISTS fire_new_ytd_manual,
  DROP COLUMN IF EXISTS fire_lost_ytd_manual,
  DROP COLUMN IF EXISTS life_new_ytd_manual,
  DROP COLUMN IF EXISTS life_lost_ytd_manual,
  DROP COLUMN IF EXISTS life_paid_for_count_ytd_manual,
  DROP COLUMN IF EXISTS life_paid_for_premium_ytd_manual;
