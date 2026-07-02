# Schema Snapshots

Point-in-time dumps of Postgres schema state (functions, later possibly triggers/policies).

Purpose: **grep-ability**. The DB tracks migration history in `supabase_migrations.schema_migrations`,
but the SQL text of past migrations lives only in that table plus this repo. When a bug needs to be
traced to "which function has this pattern," searching a snapshot file is faster than querying
`pg_proc` from a psql session.

## Files

- `functions_2026-07-02.sql` — All 126 public schema function definitions as of 2026-07-02,
  generated after the DRY sprint that extracted `get_expected_teammates`, `render_team_status_block`,
  and `compute_team_health_weekly_hits`.

## Regenerating

To create a fresh snapshot from the live DB:

```sql
SELECT string_agg(
  '-- FUNCTION: public.' || proname || '(' || pg_get_function_identity_arguments(oid) || ')' || E'\n' ||
  pg_get_functiondef(oid) || E'\n\n',
  ''
  ORDER BY proname, pg_get_function_identity_arguments(oid)
) AS full_dump
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace;
```

Save output to `functions_YYYY-MM-DD.sql`. Not required after every migration — refresh after
major schema sprints or when snapshot is >30 days stale.
