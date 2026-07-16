-- Migration: drop dead team-related tables
-- Verified 2026-07-16: 0 rows, 0 pg_proc refs, no views, no incoming FKs
-- Boilerplate RLS + auto-updated-at trigger drop with the table
DROP TABLE IF EXISTS public.team_performance CASCADE;
DROP TABLE IF EXISTS public.team_weekly_wrapups CASCADE;
