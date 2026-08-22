-- Helpers for the migration-mirror edge function.
-- The migration ledger lives in schema supabase_migrations, which PostgREST does
-- not expose. These SECURITY DEFINER wrappers let the edge function (service role)
-- diff the ledger against the repo and pull the SQL for whatever is missing.

CREATE OR REPLACE FUNCTION public.migration_mirror_stats(p_have text[])
RETURNS TABLE (ledger_total int, repo_have int, pending int, pending_bytes bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
  SELECT
    (SELECT count(*)::int FROM supabase_migrations.schema_migrations),
    coalesce(array_length(p_have, 1), 0),
    (SELECT count(*)::int FROM supabase_migrations.schema_migrations m
       WHERE NOT (m.version = ANY(coalesce(p_have, '{}'::text[])))),
    (SELECT coalesce(sum(length(array_to_string(m.statements, E'\n'))), 0)::bigint
       FROM supabase_migrations.schema_migrations m
       WHERE NOT (m.version = ANY(coalesce(p_have, '{}'::text[]))));
$fn$;

CREATE OR REPLACE FUNCTION public.migration_mirror_pending(
  p_have      text[],
  p_limit     int DEFAULT 40,
  p_max_bytes int DEFAULT 700000
)
RETURNS TABLE (version text, name text, sql_text text, bytes int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
DECLARE
  r          record;
  v_running  bigint := 0;
  v_count    int := 0;
BEGIN
  FOR r IN
    SELECT m.version AS v,
           m.name    AS n,
           array_to_string(m.statements, E'\n') AS s
    FROM supabase_migrations.schema_migrations m
    WHERE NOT (m.version = ANY(coalesce(p_have, '{}'::text[])))
    ORDER BY m.version
  LOOP
    -- Always emit at least one row, even if a single migration exceeds the byte
    -- cap on its own, so an oversized migration can never wedge the backfill.
    EXIT WHEN v_count >= p_limit;
    EXIT WHEN v_count > 0 AND v_running + length(r.s) > p_max_bytes;

    version  := r.v;
    name     := r.n;
    sql_text := r.s;
    bytes    := length(r.s);
    v_running := v_running + length(r.s);
    v_count   := v_count + 1;
    RETURN NEXT;
  END LOOP;
END;
$fn$;

REVOKE ALL ON FUNCTION public.migration_mirror_stats(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.migration_mirror_pending(text[], int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.migration_mirror_stats(text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.migration_mirror_pending(text[], int, int) TO service_role;
