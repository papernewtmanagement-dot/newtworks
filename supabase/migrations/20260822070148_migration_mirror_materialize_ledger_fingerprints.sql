-- The audit RPC was joining a VIEW that recomputes a regex-strip + sha256 over
-- every ledger row. With a lateral join that is ~2,000 recomputations per
-- audited file, i.e. half a million per 250-row batch, and the call timed out.
-- Materialise the ledger fingerprints once and index them instead.

CREATE TABLE IF NOT EXISTS public.migration_ledger_fingerprints (
  version     text PRIMARY KEY,
  name        text,
  fingerprint text NOT NULL,
  built_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_migration_ledger_fingerprints_fp
  ON public.migration_ledger_fingerprints (fingerprint);

CREATE OR REPLACE FUNCTION public.migration_ledger_fingerprints_refresh()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
DECLARE n int;
BEGIN
  INSERT INTO public.migration_ledger_fingerprints (version, name, fingerprint, built_at)
  SELECT f.version, f.name, f.fingerprint, now()
  FROM public.v_migration_ledger_fingerprints f
  ON CONFLICT (version) DO UPDATE
    SET name = EXCLUDED.name,
        fingerprint = EXCLUDED.fingerprint,
        built_at = now();
  SELECT count(*)::int INTO n FROM public.migration_ledger_fingerprints;
  RETURN n;
END;
$fn$;

-- Rewritten to hit the indexed table, and no longer returns a whole-table
-- tally on every call (that recount was a second avoidable cost).
CREATE OR REPLACE FUNCTION public.migration_mirror_record_audit(
  p_agency_id uuid,
  p_rows      jsonb
)
RETURNS TABLE (recorded int, matched int, unmatched int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  RETURN QUERY
  WITH ins AS (
    INSERT INTO public.migration_mirror_audit
      (agency_id, repo_version, repo_path, fingerprint, ledger_match_version, ledger_match_name)
    SELECT p_agency_id, r.version, r.path, r.fingerprint, lf.version, lf.name
    FROM jsonb_to_recordset(p_rows) AS r(version text, path text, fingerprint text)
    LEFT JOIN public.migration_ledger_fingerprints lf
      ON lf.fingerprint = r.fingerprint
    ON CONFLICT (agency_id, repo_path) DO UPDATE
      SET fingerprint          = EXCLUDED.fingerprint,
          ledger_match_version = EXCLUDED.ledger_match_version,
          ledger_match_name    = EXCLUDED.ledger_match_name,
          checked_at           = now()
    RETURNING ledger_match_version
  )
  SELECT count(*)::int,
         count(*) FILTER (WHERE ledger_match_version IS NOT NULL)::int,
         count(*) FILTER (WHERE ledger_match_version IS NULL)::int
  FROM ins;
END;
$fn$;

REVOKE ALL ON FUNCTION public.migration_ledger_fingerprints_refresh() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.migration_ledger_fingerprints_refresh() TO service_role;
