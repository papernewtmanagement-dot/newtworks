-- The column was added 2026-06-16 to power the Retention tab calculator
-- as a stored "current" value. Replaced 2026-06-16 by runtime function
-- public.compute_on_time_smvc_with_better_of(). UI no longer reads it.
-- Dropping per Peter's confirmation 2026-06-16.

ALTER TABLE public.agency DROP COLUMN IF EXISTS on_time_smvc_current;
