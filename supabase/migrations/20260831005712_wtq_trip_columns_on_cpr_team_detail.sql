-- Win the Quarter trip result is recorded on the EXISTING CPR team-member rows for the
-- last week of the quarter (Peter directive 2026-08-29: no separate table).
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS wtq_trip_dollars numeric,
  ADD COLUMN IF NOT EXISTS wtq_quarter_mvp  boolean;

COMMENT ON COLUMN public.weekly_cpr_team_detail.wtq_trip_dollars IS
  'Win the Quarter trip dollars for this person, after the 50/50 split. Written only on the '
  'last week of a quarter by quarter_close_wtq. NULL every other week. 0 when the trip is '
  'halted (fewer than 9 wins).';

COMMENT ON COLUMN public.weekly_cpr_team_detail.wtq_quarter_mvp IS
  'True for the Quarter MVP (most Sales Points across the quarter), who takes the 50% MVP '
  'half. Written only on the last week of a quarter by quarter_close_wtq.';
