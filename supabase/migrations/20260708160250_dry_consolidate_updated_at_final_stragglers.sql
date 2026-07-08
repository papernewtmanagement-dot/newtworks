-- Follow-up cleanup: tg_team_licenses_updated_at slipped past the first pass
-- because a whitespace difference (no newline before final END) put it in a
-- different content hash bucket. Body is semantically identical:
--   BEGIN NEW.updated_at := now(); RETURN NEW; END
--
-- Final result: 147 -> 146 total functions; 27 -> 28 triggers on canonical.

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
  END LOOP;

  DROP FUNCTION IF EXISTS public.tg_team_licenses_updated_at();
END $$;
