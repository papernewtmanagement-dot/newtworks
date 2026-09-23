-- Nothing in the Family area should be callable without signing in. Every function
-- matched here already carries its own grant to signed-in users (authenticated=X),
-- so only the open PUBLIC grant goes. Found by the security check on 2026-09-23.
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.proname LIKE 'family%' OR p.proname = 'auth_is_family')
      AND COALESCE(p.proacl::text, '') LIKE '%authenticated=X%'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);
  END LOOP;
END $$;
