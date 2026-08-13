-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 16:01:52 UTC (ledger name: dry_consolidate_updated_at_final_stragglers) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708160152.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Follow-up cleanup: tg_team_licenses_updated_at slipped past the first pass
-- because a whitespace difference (no newline before final END) put it in a
-- different content hash bucket. Body is semantically identical:
--   BEGIN NEW.updated_at := now(); RETURN NEW; END

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT t.tgname, c.relname AS table_name, n.nspname AS schema_name
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE NOT t.tgisinternal
      AND p.proname = 'tg_team_licenses_updated_at'
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I.%I', r.tgname, r.schema_name, r.table_name);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      r.tgname, r.schema_name, r.table_name
    );
    RAISE NOTICE 'Repointed %.% trigger %', r.schema_name, r.table_name, r.tgname;
  END LOOP;

  DROP FUNCTION IF EXISTS public.tg_team_licenses_updated_at();
END $$;
