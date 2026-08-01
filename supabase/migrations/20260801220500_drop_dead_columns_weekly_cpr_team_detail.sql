-- Drop 16 dead columns from weekly_cpr_team_detail.
-- Group 1 (11 cols): legacy per-teammate checklist booleans, superseded by
--   report-level checklist on weekly_cpr_reports (EDIT_FIELDS.report in
--   CPRDetail.jsx). Only 10/59 rows had data, all pre-dating the move.
--   Nothing in current code reads or writes these on this table.
-- Group 2 (5 cols): carryover/missed/cost/total/paid. All default to 0,
--   nothing computes or updates them post-insert. Paid/Owed math is
--   computed live by get_weekly_cpr_requirements() and never stored.
-- Flagged as pending-drop in op-rule "CPR data model" (2026-07-22); never executed until now.
-- Confirmed via pg_get_functiondef scan: no live function reads/writes
-- these columns qualified against weekly_cpr_team_detail.

ALTER TABLE public.weekly_cpr_team_detail
  DROP COLUMN IF EXISTS shareds_done,
  DROP COLUMN IF EXISTS texts_done,
  DROP COLUMN IF EXISTS deposits_done,
  DROP COLUMN IF EXISTS appts_done,
  DROP COLUMN IF EXISTS tasks_done,
  DROP COLUMN IF EXISTS cases_done,
  DROP COLUMN IF EXISTS no_fu_task_done,
  DROP COLUMN IF EXISTS new_opps_done,
  DROP COLUMN IF EXISTS no_onboarding_done,
  DROP COLUMN IF EXISTS no_phone_done,
  DROP COLUMN IF EXISTS bad_data_done,
  DROP COLUMN IF EXISTS carryover,
  DROP COLUMN IF EXISTS missed,
  DROP COLUMN IF EXISTS cost,
  DROP COLUMN IF EXISTS total,
  DROP COLUMN IF EXISTS paid;
