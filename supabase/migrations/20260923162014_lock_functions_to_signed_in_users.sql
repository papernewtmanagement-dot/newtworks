-- Lock every public function to signed-in users and the server.
--
-- Before: Postgres gives every new function EXECUTE to PUBLIC, so the website's
-- public key could call 378 public functions with no login (247 of them run
-- with full data access). 28 also carried a hand-made anon grant.
--
-- Who needs a no-login grant: nobody. Mapped 2026-09-23:
--   /assess, /schedule, /accept-offer pages -> v1-assessment, hiring-interview-scheduler,
--     hiring-offer-accept (server programs using the service role key)
--   /careers, /jobs.xml -> careers-site, jobs-xml-feed (service role key)
--   Indeed, ZipRecruiter, CareerPlug, Telegram -> their server programs (service role key)
--   login page -> auth service only; the two auth.users triggers need no grant
--     (tested: a trigger runs even when the caller cannot execute its function)
--   pg_cron -> postgres; automation runner and dispatchers -> service role key
-- Evidence: 24h of web logs and 16 days of pg_stat_statements showed zero
-- function calls under the anon role.
--
-- Part 1 takes PUBLIC and anon off every public function anon can run.
-- Signed-in users keep their own explicit grant. The block fails, and nothing
-- changes, if any signed-in or service role grant would be lost.
-- Part 2 fixes the cause: functions postgres creates from now on no longer get
-- the open PUBLIC grant. New public functions still get authenticated and
-- service_role through the existing public-schema default. Extensions are
-- created by supabase_admin and are not affected (tested 2026-09-23). A new
-- function in any OTHER schema now needs an explicit grant to be callable.
DO $$
DECLARE
  f record;
  n_auth_before int; n_svc_before int;
  n_auth_after int;  n_svc_after int;  n_anon_after int; n_public_after int;
  n_closed int := 0;
BEGIN
  SELECT count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('service_role',  p.oid, 'EXECUTE'))
    INTO n_auth_before, n_svc_before
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public';

  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    n_closed := n_closed + 1;
  END LOOP;

  SELECT count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('service_role',  p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE has_function_privilege('anon',          p.oid, 'EXECUTE')),
         count(*) FILTER (WHERE p.proacl IS NULL
                             OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                                         WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
    INTO n_auth_after, n_svc_after, n_anon_after, n_public_after
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public';

  IF n_anon_after <> 0 THEN
    RAISE EXCEPTION 'lockdown incomplete: % public functions still open to anon', n_anon_after;
  END IF;
  IF n_public_after <> 0 THEN
    RAISE EXCEPTION 'lockdown incomplete: % public functions still open to PUBLIC', n_public_after;
  END IF;
  IF n_auth_after <> n_auth_before THEN
    RAISE EXCEPTION 'signed-in users would lose % functions', n_auth_before - n_auth_after;
  END IF;
  IF n_svc_after <> n_svc_before THEN
    RAISE EXCEPTION 'service role would lose % functions', n_svc_before - n_svc_after;
  END IF;
  RAISE NOTICE 'closed % public functions to no-login use; signed-in keeps %, service role keeps %',
    n_closed, n_auth_after, n_svc_after;
END $$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
