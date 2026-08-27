-- Every SQL-side dispatch to an edge function must carry an Authorization
-- header. Without one the Supabase gateway answers 401 before the function
-- runs, and pg_net is fire-and-forget so the caller reports "dispatched"
-- and nothing anywhere records a failure.
--
-- This is NOT hypothetical: generate-signature sat broken for three
-- sessions because of exactly this, and run_migration_mirror_nightly had
-- already been patched by hand for the same reason without the lesson
-- being applied anywhere else.
--
-- The gate (verify_jwt) resets to true on EVERY deploy. Rather than rely
-- on anyone remembering to switch it back off, the dispatchers now always
-- satisfy it. The shared_secret in the body remains the real
-- authentication; this header only gets the request past the front door.

CREATE OR REPLACE FUNCTION public.edge_fn_headers()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || COALESCE(
      (SELECT setting_value FROM public.settings
        WHERE setting_key = 'supabase_service_role_key'
        LIMIT 1), '')
  );
$fn$;

COMMENT ON FUNCTION public.edge_fn_headers() IS
'Canonical headers for any net.http_post to a Supabase edge function. Always use this instead of building headers inline - it guarantees the Authorization header that keeps the gateway from rejecting the call with 401 whenever verify_jwt is on (which every deploy re-enables).';

-- Repoint all six inline dispatchers at the helper.
DO $mig$
DECLARE
  v_name    text;
  v_def     text;
  v_new     text;
  v_names   text[] := ARRAY[
    '_dispatch_edge_fn',
    'dispatch_assessed_candidate',
    'payroll_weekly_nag',
    'run_automation_recipe',
    'send_signature_email',
    'team_trajectory_recompute'
  ];
  v_count   int;
BEGIN
  FOREACH v_name IN ARRAY v_names LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_def IS NULL THEN
      RAISE EXCEPTION 'function % not found', v_name;
    END IF;

    -- Both spacing variants appear across these six.
    v_new := replace(v_def,
      'jsonb_build_object(''Content-Type'', ''application/json'')',
      'public.edge_fn_headers()');
    v_new := replace(v_new,
      'jsonb_build_object(''Content-Type'',''application/json'')',
      'public.edge_fn_headers()');

    IF v_new = v_def THEN
      RAISE EXCEPTION 'no headers expression matched in % - refusing to leave it unpatched', v_name;
    END IF;

    EXECUTE v_new;
  END LOOP;

  -- Verify: no public function may still post to an edge function without auth.
  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_functiondef(p.oid) ILIKE '%net.http_post%'
    AND pg_get_functiondef(p.oid) ILIKE '%/functions/v1%'
    AND pg_get_functiondef(p.oid) NOT ILIKE '%Authorization%'
    AND pg_get_functiondef(p.oid) NOT ILIKE '%edge_fn_headers%';

  IF v_count > 0 THEN
    RAISE EXCEPTION '% dispatcher(s) still send no Authorization header', v_count;
  END IF;
END $mig$;
