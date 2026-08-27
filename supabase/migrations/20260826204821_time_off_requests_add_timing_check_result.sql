-- Stores the quarter-timing / length check alongside the existing notice, eligibility
-- and coverage check snapshots, so the agent's review screen can show WHY a request
-- landed as case-by-case. Handbook 02 Hours & Time Off: time off sits after the first
-- four weeks of a quarter and runs up to one week at a time; a "Great" rating lifts the
-- first-four-weeks limit and an "Elite" rating lifts the one-week limit.
ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS timing_check_result jsonb;

COMMENT ON COLUMN public.time_off_requests.timing_check_result IS
  'Snapshot of the quarter-timing/length check at submit time: in_first_four_weeks, exceeds_one_week, day_of_quarter, span_days, clears_first_four_weeks (from time_off_check_eligibility.may_start_in_first_four_weeks), clears_one_week (from may_exceed_one_week), needs_agent_ok, messages.';
