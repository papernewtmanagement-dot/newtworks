-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-12 22:17:21 UTC (ledger name: lock_chart_of_accounts_and_master_codes) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260812221721.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

CREATE OR REPLACE FUNCTION public.block_chart_of_accounts_writes()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'chart_of_accounts / account_master_codes is locked. Requires Peter''s explicit permission to add, edit, or remove accounts. To make an approved change: DROP TRIGGER, make the change, then recreate the trigger.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS lock_chart_of_accounts ON public.chart_of_accounts;
CREATE TRIGGER lock_chart_of_accounts
  BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.block_chart_of_accounts_writes();

DROP TRIGGER IF EXISTS lock_account_master_codes ON public.account_master_codes;
CREATE TRIGGER lock_account_master_codes
  BEFORE INSERT OR UPDATE OR DELETE ON public.account_master_codes
  FOR EACH ROW EXECUTE FUNCTION public.block_chart_of_accounts_writes();
