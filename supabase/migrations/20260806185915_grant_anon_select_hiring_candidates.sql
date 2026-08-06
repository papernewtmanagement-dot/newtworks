-- hiring_candidates has an RLS policy allowing SELECT to everyone (USING true),
-- but Postgres also requires a base table GRANT before RLS is even consulted.
-- anon never had that grant — only authenticated did. Since the Newtworks
-- frontend runs on the plain anon key with no login, every anon query against
-- hiring_candidates (directly, or via v_hiring_candidates) failed with
-- "permission denied for table hiring_candidates". This predates today's
-- CTS-retirement migrations; the app never worked for anon on this table.
GRANT SELECT ON public.hiring_candidates TO anon;
