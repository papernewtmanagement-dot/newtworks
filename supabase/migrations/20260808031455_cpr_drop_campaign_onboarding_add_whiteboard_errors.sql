ALTER TABLE public.weekly_cpr_reports
  DROP COLUMN IF EXISTS campaign_onboarding_date;

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS whiteboard_errors text;

COMMENT ON COLUMN public.weekly_cpr_reports.whiteboard_errors IS
  'Free-form weekly whiteboard errors log, mirrors eur column. Displayed to the right of EUR on the CPR page. Each line is intended to add +1 to the team requirements count (get_weekly_cpr_requirements) — that wiring is NOT YET IMPLEMENTED as of migration date; pending Peter confirmation on exact mechanic.';
