-- Adds weekly_cpr_reports.wrapup_summary_text — the Claude-drafted consolidated
-- team wrap-up summary section, sibling to opener_text + looking_next_week_text.
-- Per-teammate raw content stays on weekly_cpr_team_detail.wrapup_text (fed by
-- document-processor wrapup mode); this new column stores the compiled cross-team
-- summary Claude writes when Peter asks to draft the CPR.
ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS wrapup_summary_text text;

COMMENT ON COLUMN public.weekly_cpr_reports.wrapup_summary_text IS
  'Claude-drafted consolidated team wrap-up summary. Compiled across all teammates'' wrapup_text on weekly_cpr_team_detail for the week. Rendered by compose_weekly_cpr_html between opener and WEEKLY PAY. Editable via CPRDetail (Owner only).';
