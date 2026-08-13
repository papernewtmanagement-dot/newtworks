-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-05 23:16:29 UTC (ledger name: chart_of_accounts_flat_section_guard) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260805231629.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- Defense in depth: even with the query-side fix, a non-agency income/expense
-- account created with section_label_override left NULL was the exact seed of
-- this bug recurring. Auto-fill flat 'Income'/'Expense' at write time for every
-- entity except the agency (PSS), so the gap can't reopen silently.
CREATE OR REPLACE FUNCTION public.enforce_flat_pnl_section_non_agency()
RETURNS trigger
LANGUAGE plpgsql
AS $trigger$
BEGIN
  IF NEW.business_entity_id IS DISTINCT FROM 'b2222222-2222-2222-2222-222222222222'::uuid
     AND NEW.account_type IN ('income','expense')
     AND NEW.section_label_override IS NULL THEN
    NEW.section_label_override := INITCAP(NEW.account_type::text);
  END IF;
  RETURN NEW;
END;
$trigger$;

DROP TRIGGER IF EXISTS trg_enforce_flat_pnl_section_non_agency ON public.chart_of_accounts;
CREATE TRIGGER trg_enforce_flat_pnl_section_non_agency
  BEFORE INSERT OR UPDATE ON public.chart_of_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_flat_pnl_section_non_agency();
