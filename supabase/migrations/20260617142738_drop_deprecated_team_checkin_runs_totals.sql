-- Drop the deprecated totals columns from team_checkin_runs.
-- Totals are now always computed at runtime per the standing rule established 2026-06-17.
-- No functional code reads these columns; the only remaining reference was a comment in
-- team_checkin_compile_results documenting that it stopped writing them.

ALTER TABLE public.team_checkin_runs
  DROP COLUMN IF EXISTS total_quotes_week,
  DROP COLUMN IF EXISTS total_sales_points_quarter;
