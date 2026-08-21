-- Defense-in-depth: anon should be a read-only role at the grant layer.
-- RLS already blocks anon writes (no write policies exist), so this is
-- functionally inert today but removes the latent risk of a future
-- permissive RLS policy turning into an actual write hole.
-- Strategy: revoke ALL on every table, then re-grant SELECT only.
-- SELECT preserves every dashboard read. Reversible by re-granting.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM anon;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;

-- Ensure future tables created in this schema also default to SELECT-only
-- for anon (so we don't silently regress on the next table add).
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
