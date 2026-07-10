-- Drop unnecessary duplicate table.
-- book_growth_targets was created 2026-07-10 as a new home for annual growth targets,
-- but the existing book_performance_goals table already holds Peter's 2026 targets.
-- Book/Goals tab refactored to read from book_performance_goals; this table is unused.

DROP TABLE IF EXISTS public.book_growth_targets;
