ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS scorecard_done boolean;

COMMENT ON COLUMN public.weekly_cpr_team_detail.scorecard_done IS
  'Personal checklist: did the team member complete their FIT scorecarding for the CPR week? Auto-verified on CPRDetail page load against fit_scorecards (>=1 entry with scorecard_date in the Sun-Sat window). Manual override in edit mode possible but overwritten on next page load.';
