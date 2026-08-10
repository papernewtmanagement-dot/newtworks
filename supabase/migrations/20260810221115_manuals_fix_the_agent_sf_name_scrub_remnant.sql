-- Peter directive 2026-08-10: finish the "the agent State Farm" name-scrub repair.
-- The "your local the agent State Farm" spoken-script instances were already fixed
-- earlier today by another session (verified: zero pages contain "the agent State Farm").
-- The same 2026-07-07 scrub damage survives in a second shape, "the agent SF", on eight
-- admin reference pages. Replacing with the agency trading name.
--
-- Deliberately NOT touched: every other "the agent" occurrence (72 pages). Those are
-- correct role references under the no-personal-names rule -- "approval from the agent",
-- "at the agent's discretion", "a bonus from the agent", "## the agent's Use Cases".
-- Verified by reading the surrounding sentence on each match pattern, not by count alone.

UPDATE public.manuals
SET content = replace(content, 'the agent SF', 'Peter Story State Farm'),
    version = COALESCE(version, 0) + 1,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND content LIKE '%the agent SF%';
