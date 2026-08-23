-- The safe-to-delete set, defined narrowly and recomputed live rather than
-- trusted from an earlier count.
--
-- A repo file is prunable ONLY when BOTH hold:
--   1. its own version is NOT in the ledger  — so deleting it removes no
--      ledger-backed migration; and
--   2. its content fingerprint DOES match some ledger version — so an
--      identical copy is already tracked and nothing is lost.
--
-- After adopting the 192 unledgered files, their versions now satisfy (1)'s
-- negation, so they drop out of this set automatically. That is deliberate:
-- the definition, not a hardcoded list, is what protects them.

CREATE OR REPLACE FUNCTION public.migration_mirror_prunable(p_agency_id uuid)
RETURNS TABLE (repo_path text, repo_version text, ledger_match_version text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
  SELECT a.repo_path, a.repo_version, a.ledger_match_version
  FROM public.migration_mirror_audit a
  WHERE a.agency_id = p_agency_id
    AND a.ledger_match_version IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM supabase_migrations.schema_migrations m
      WHERE m.version = a.repo_version
    )
  ORDER BY a.repo_path;
$fn$;

REVOKE ALL ON FUNCTION public.migration_mirror_prunable(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.migration_mirror_prunable(uuid) TO service_role;
