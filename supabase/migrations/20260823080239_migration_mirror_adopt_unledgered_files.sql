-- Adopt repo migration files whose SQL appears nowhere in the ledger.
--
-- These 192 files are the sole record of changes that were genuinely applied
-- (verified against live objects) but applied outside Supabase MCP, so the
-- ledger never saw them. Registering them makes the ledger a complete history
-- for the first time, which is the only state in which "the ledger is
-- authoritative" is a true statement.
--
-- ON CONFLICT DO NOTHING: adopting is never allowed to overwrite a real applied
-- migration. If a version somehow already exists, the ledger row wins.

CREATE OR REPLACE FUNCTION public.migration_mirror_adopt(p_rows jsonb)
RETURNS TABLE (adopted int, skipped int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
DECLARE
  v_in      int;
  v_adopted int;
BEGIN
  SELECT count(*)::int INTO v_in
  FROM jsonb_to_recordset(p_rows) AS r(version text, name text, sql_text text);

  WITH ins AS (
    INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
    SELECT r.version, r.name, ARRAY[r.sql_text]
    FROM jsonb_to_recordset(p_rows) AS r(version text, name text, sql_text text)
    ON CONFLICT (version) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_adopted FROM ins;

  RETURN QUERY SELECT v_adopted, v_in - v_adopted;
END;
$fn$;

REVOKE ALL ON FUNCTION public.migration_mirror_adopt(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.migration_mirror_adopt(jsonb) TO service_role;
