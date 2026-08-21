-- Per-week sales-points target snapshot (locked at the week's writer run)
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS sales_points_target_this_week numeric;

COMMENT ON COLUMN public.weekly_cpr_reports.sales_points_target_this_week IS
  'This-week-only increment of the sales-points target. Snapshotted by weekly_cpr_compute_outcome from the team composition at week start (Monday). quarterly_sales_points_target = prior week cumulative + this week''s value.';

-- Campaign dates stored directly on the CPR row. Prior-row prefill in the UI.
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS campaign_onboarding_date date,
  ADD COLUMN IF NOT EXISTS campaign_defectors_date date,
  ADD COLUMN IF NOT EXISTS campaign_single_line_date date,
  ADD COLUMN IF NOT EXISTS campaign_af_renewals_date date;

COMMENT ON COLUMN public.weekly_cpr_reports.campaign_onboarding_date IS
  'Most recent run date of the Onboarding campaign as of this CPR week. NULL = no run logged this week; UI prefills from most recent prior week with a non-NULL value.';
COMMENT ON COLUMN public.weekly_cpr_reports.campaign_defectors_date IS
  'Most recent run date of the Defectors campaign. NULL means UI prefills from most recent prior week.';
COMMENT ON COLUMN public.weekly_cpr_reports.campaign_single_line_date IS
  'Most recent run date of the Single-Line At-Risk campaign. NULL means UI prefills from most recent prior week.';
COMMENT ON COLUMN public.weekly_cpr_reports.campaign_af_renewals_date IS
  'Most recent run date of the A/F Renewals campaign. NULL means UI prefills from most recent prior week.';

-- Manual per-person quote adjustment column. owed = (total + modified) - paid.
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS quotes_modified integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.weekly_cpr_team_detail.quotes_modified IS
  'Signed manual adjustment to this person''s quote requirement for the week. Positive = add to owed; negative = forgive. Owed = (total + modified) - paid in get_weekly_cpr_requirements.';
