-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-07 16:52:59 UTC (ledger name: fix_fn_verify_rls_read_access_ambiguous_column) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260807165259.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.fn_verify_rls_read_access(
  p_tables text[],
  p_test_auth_user_id uuid DEFAULT 'dc9a6291-6d79-410b-9870-ff5d0c81a7f0'
)
RETURNS TABLE (
  table_name text,
  tested_role text,
  has_rls boolean,
  select_policy_count integer,
  has_select_grant boolean,
  true_row_count bigint,
  role_row_count bigint,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  t text;
  r text;
  v_true_count bigint;
  v_role_count bigint;
  v_has_rls boolean;
  v_select_policy_count integer;
  v_status text;
  v_roles text[];
BEGIN
  FOREACH t IN ARRAY p_tables LOOP

    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t AND c.relkind IN ('r','p')
    ) THEN
      table_name := t; tested_role := NULL; has_rls := NULL; select_policy_count := NULL;
      has_select_grant := false; true_row_count := NULL; role_row_count := NULL;
      status := 'TABLE_NOT_FOUND';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT c.relrowsecurity INTO v_has_rls
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = t;

    SELECT count(*) INTO v_select_policy_count
    FROM pg_policies pp
    WHERE pp.schemaname = 'public' AND pp.tablename = t AND pp.cmd IN ('SELECT','ALL');

    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO v_true_count;

    SELECT array_agg(DISTINCT rtg.grantee) INTO v_roles
    FROM information_schema.role_table_grants rtg
    WHERE rtg.table_schema = 'public' AND rtg.table_name = t AND rtg.privilege_type = 'SELECT'
      AND rtg.grantee IN ('anon','authenticated');

    IF v_roles IS NULL THEN
      table_name := t; tested_role := NULL; has_rls := v_has_rls;
      select_policy_count := v_select_policy_count; has_select_grant := false;
      true_row_count := v_true_count; role_row_count := NULL;
      status := 'NO_ROLE_GRANT';
      RETURN NEXT;
      CONTINUE;
    END IF;

    FOREACH r IN ARRAY v_roles LOOP

      IF r = 'authenticated' THEN
        PERFORM set_config(
          'request.jwt.claims',
          json_build_object('sub', p_test_auth_user_id::text, 'role','authenticated')::text,
          true
        );
      ELSE
        PERFORM set_config('request.jwt.claims', '{}', true);
      END IF;

      EXECUTE format('SET LOCAL ROLE %I', r);
      BEGIN
        EXECUTE format('SELECT count(*) FROM public.%I', t) INTO v_role_count;
      EXCEPTION WHEN OTHERS THEN
        v_role_count := -1;
      END;
      RESET ROLE;

      v_status := CASE
        WHEN NOT v_has_rls THEN 'NO_RLS'
        WHEN v_select_policy_count = 0 THEN 'RLS_NO_SELECT_POLICY'
        WHEN v_role_count = -1 THEN 'QUERY_ERROR'
        WHEN v_true_count > 0 AND v_role_count = 0 THEN 'BLOCKED_READ'
        ELSE 'OK'
      END;

      table_name := t;
      tested_role := r;
      has_rls := v_has_rls;
      select_policy_count := v_select_policy_count;
      has_select_grant := true;
      true_row_count := v_true_count;
      role_row_count := v_role_count;
      status := v_status;
      RETURN NEXT;

    END LOOP;
  END LOOP;
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_verify_rls_read_access(text[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_verify_rls_read_access(text[], uuid) TO postgres, service_role;
