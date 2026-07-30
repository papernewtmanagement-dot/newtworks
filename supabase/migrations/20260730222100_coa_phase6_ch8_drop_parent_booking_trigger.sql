-- Phase 6 Ch8 — drop the direct-to-parent booking trigger (dead post-Phase-6).
-- The trigger blocked journal_lines from targeting an income/expense root that has children.
-- Post-Phase-6, all active COAs are effectively roots (parent NULL), all inactive folder parents
-- are deleted, no COA has children. The check always returns FALSE. Trigger becomes a no-op that
-- fires on every journal_line write. Dropping it eliminates the overhead and cleans up dead defense.

DROP TRIGGER IF EXISTS tg_reject_direct_to_parent_booking ON public.journal_lines;
DROP FUNCTION IF EXISTS public.tg_reject_direct_to_parent_booking_fn();
