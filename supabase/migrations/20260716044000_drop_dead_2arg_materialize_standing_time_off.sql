-- Drop dead 2-arg overload of materialize_standing_time_off.
--
-- Three overloads existed:
--   (uuid, uuid)          — recipe wrapper, delegates to 3-arg. KEEP.
--   (uuid, date)           — legacy pre-gate version. DEAD. DROP HERE.
--   (uuid, date, boolean)  — canonical live version with role + quote gates. KEEP.
--
-- The 2-arg version predates the lookahead-guard (added 2026-07-15) and the
-- role/quote gates (added 2026-07-16). Recipe wrapper was migrated to call the
-- 3-arg version, so nothing in prod invokes the 2-arg. Grep of the frontend +
-- edge functions + migrations confirms zero live callers (only the original
-- 20260715230000 migration file references it, and migrations run once).
--
-- Leaving it in place is a footgun: a hand-typed `SELECT materialize_standing_time_off(agency_id, some_date)`
-- would silently resolve to the pre-gate function and materialize time off for
-- AAs/non-quote-hitters, contradicting the canonical WtW rule.
--
-- Reversible via CREATE OR REPLACE FUNCTION if ever needed.

DROP FUNCTION IF EXISTS public.materialize_standing_time_off(uuid, date);
