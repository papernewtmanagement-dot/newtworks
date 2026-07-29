-- 2026-07-29: Kill the trigger that auto-stamps journal_entries.business_entity_id
-- with agency (b2222222) as default. This was the root cause of the JE/JL entity
-- mismatch — every writer that didn't explicitly set entity got poisoned. Under
-- Thread B's architecture (P&L filters by coa.business_entity_id), the JE stamp
-- is unnecessary and drift-prone.

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.journal_entries;
