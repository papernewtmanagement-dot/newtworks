-- Drop cts_invited_by column. Added earlier same day in 20260716220000; removed on Peter's directive.
-- Not consumed by any function or repo file at time of drop.
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS cts_invited_by;
