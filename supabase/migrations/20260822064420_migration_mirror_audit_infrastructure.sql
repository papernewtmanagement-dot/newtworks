-- Audit support for the migration mirror.
--
-- Question being answered: the repo holds 2,842 migration versions but the
-- ledger only 2,019. Every ledger row IS mirrored (pending = 0), so ~823 repo
-- versions have no ledger row. Some are byte-identical duplicates of a ledger
-- migration under an invented timestamp. Others differ only by an added
-- comment header, which hides them from a plain blob-hash comparison. And some
-- may be genuinely unique SQL that never went through the ledger at all.
--
-- FINGERPRINT: sha256 over the SQL with -- line comments removed and ALL
-- whitespace stripped. Comment headers and reformatting stop mattering; real
-- differences in SQL still do. The edge function computes the repo side with
-- the identical two regexes so the two are comparable.

CREATE OR REPLACE VIEW public.v_migration_ledger_fingerprints AS
SELECT
  m.version,
  m.name,
  encode(sha256(convert_to(
    regexp_replace(
      regexp_replace(array_to_string(m.statements, E'\n'), '--[^\n]*', '', 'g'),
      '\s+', '', 'g'),
    'UTF8')), 'hex') AS fingerprint
FROM supabase_migrations.schema_migrations m;

CREATE TABLE IF NOT EXISTS public.migration_mirror_audit (
  id                   uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id            uuid NOT NULL,
  repo_version         text NOT NULL,
  repo_path            text NOT NULL,
  fingerprint          text NOT NULL,
  ledger_match_version text,          -- NULL = content found nowhere in ledger
  ledger_match_name    text,
  checked_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, repo_path)
);

ALTER TABLE public.migration_mirror_audit ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.migration_mirror_repo_only(p_repo_versions text[])
RETURNS TABLE (version text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
  SELECT v
  FROM unnest(coalesce(p_repo_versions, '{}'::text[])) AS v
  WHERE NOT EXISTS (
    SELECT 1 FROM supabase_migrations.schema_migrations m WHERE m.version = v
  );
$fn$;

-- p_rows: [{ "version": "...", "path": "...", "fingerprint": "..." }, ...]
CREATE OR REPLACE FUNCTION public.migration_mirror_record_audit(
  p_agency_id uuid,
  p_rows      jsonb
)
RETURNS TABLE (recorded int, matched int, unmatched int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, supabase_migrations
AS $fn$
BEGIN
  INSERT INTO public.migration_mirror_audit
    (agency_id, repo_version, repo_path, fingerprint, ledger_match_version, ledger_match_name)
  SELECT
    p_agency_id,
    r.version,
    r.path,
    r.fingerprint,
    lf.version,
    lf.name
  FROM jsonb_to_recordset(p_rows) AS r(version text, path text, fingerprint text)
  LEFT JOIN LATERAL (
    SELECT f.version, f.name
    FROM public.v_migration_ledger_fingerprints f
    WHERE f.fingerprint = r.fingerprint
    ORDER BY f.version
    LIMIT 1
  ) lf ON true
  ON CONFLICT (agency_id, repo_path) DO UPDATE
    SET fingerprint          = EXCLUDED.fingerprint,
        ledger_match_version = EXCLUDED.ledger_match_version,
        ledger_match_name    = EXCLUDED.ledger_match_name,
        checked_at           = now();

  RETURN QUERY
  SELECT
    count(*)::int,
    count(*) FILTER (WHERE a.ledger_match_version IS NOT NULL)::int,
    count(*) FILTER (WHERE a.ledger_match_version IS NULL)::int
  FROM public.migration_mirror_audit a
  WHERE a.agency_id = p_agency_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.migration_mirror_repo_only(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.migration_mirror_record_audit(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.migration_mirror_repo_only(text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.migration_mirror_record_audit(uuid, jsonb) TO service_role;
