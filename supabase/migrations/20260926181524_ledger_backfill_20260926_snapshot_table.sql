-- Backup of ledger rows removed on 2026-09-26 when their statement lines were
-- re-run through corrected rules (Agency Comp skip, "Transfer From Account" skip,
-- old gas-station rule that caught "Mobile Banking Transfer", CD purchase to 1016).
-- Same columns as public.ledger. Restore = INSERT INTO public.ledger SELECT * FROM this table.
CREATE TABLE IF NOT EXISTS public.ledger_backfill_20260926 (LIKE public.ledger INCLUDING DEFAULTS);
ALTER TABLE public.ledger_backfill_20260926 ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.ledger_backfill_20260926 IS
  'Snapshot of ledger rows removed 2026-09-26 so corrected gl_classification_rules could rebuild them. Restore with INSERT INTO public.ledger SELECT * FROM public.ledger_backfill_20260926.';
