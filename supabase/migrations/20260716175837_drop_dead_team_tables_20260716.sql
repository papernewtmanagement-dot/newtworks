-- Drop truly-dead team tables verified 2026-07-16
-- team_performance: 0 rows, 0 pg_proc refs, no views, no incoming FKs
-- team_weekly_wrapups: 0 rows, 0 pg_proc refs, no views, no incoming FKs
DROP TABLE IF EXISTS public.team_performance CASCADE;
DROP TABLE IF EXISTS public.team_weekly_wrapups CASCADE;
