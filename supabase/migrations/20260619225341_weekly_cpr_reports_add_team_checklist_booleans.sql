-- Move team-level checklist booleans from per-person (weekly_cpr_team_detail) to report-level (weekly_cpr_reports).
-- 11 daily-ops + opportunity-product-list booleans. Team-level by nature; previously duplicated × 5 people.
-- This is the additive half. The destructive drop on weekly_cpr_team_detail comes later in the restructure.
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS shareds_done       boolean,
  ADD COLUMN IF NOT EXISTS texts_done         boolean,
  ADD COLUMN IF NOT EXISTS deposits_done      boolean,
  ADD COLUMN IF NOT EXISTS appts_done         boolean,
  ADD COLUMN IF NOT EXISTS tasks_done         boolean,
  ADD COLUMN IF NOT EXISTS cases_done         boolean,
  ADD COLUMN IF NOT EXISTS no_fu_task_done    boolean,
  ADD COLUMN IF NOT EXISTS new_opps_done      boolean,
  ADD COLUMN IF NOT EXISTS no_onboarding_done boolean,
  ADD COLUMN IF NOT EXISTS no_phone_done      boolean,
  ADD COLUMN IF NOT EXISTS bad_data_done      boolean;

COMMENT ON COLUMN public.weekly_cpr_reports.shareds_done       IS 'Team checklist (daily ops): Shared Outlook folders recorded and deleted';
COMMENT ON COLUMN public.weekly_cpr_reports.texts_done         IS 'Team checklist (daily ops): Texts recorded and hidden';
COMMENT ON COLUMN public.weekly_cpr_reports.deposits_done      IS 'Team checklist (daily ops): Deposits finalized';
COMMENT ON COLUMN public.weekly_cpr_reports.appts_done         IS 'Team checklist (daily ops): Appointments formatted';
COMMENT ON COLUMN public.weekly_cpr_reports.tasks_done         IS 'Team checklist (daily ops): Tasks cleared';
COMMENT ON COLUMN public.weekly_cpr_reports.cases_done         IS 'Team checklist (daily ops): Non-onboarding cases closed';
COMMENT ON COLUMN public.weekly_cpr_reports.no_fu_task_done    IS 'Team checklist (opp lists): No follow-up tasks';
COMMENT ON COLUMN public.weekly_cpr_reports.new_opps_done      IS 'Team checklist (opp lists): New contacts';
COMMENT ON COLUMN public.weekly_cpr_reports.no_onboarding_done IS 'Team checklist (daily ops): New household onboarding cases created';
COMMENT ON COLUMN public.weekly_cpr_reports.no_phone_done      IS 'Team checklist (opp lists): No phone';
COMMENT ON COLUMN public.weekly_cpr_reports.bad_data_done      IS 'Team checklist (opp lists): Quotes missing data';
