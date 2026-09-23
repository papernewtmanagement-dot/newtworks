-- Family and Course go back to: site admins + the family login. No entity gate.
-- team.business_entity_id is untouched.
DO $$
DECLARE p record; v_to text; v_sql text; f record;
BEGIN
  FOR p IN SELECT * FROM pg_policies WHERE schemaname='public' AND tablename LIKE 'family%'
           AND (qual LIKE '%family_member()%' OR with_check LIKE '%family_member()%') LOOP
    SELECT string_agg(CASE WHEN r='public' THEN 'public' ELSE quote_ident(r) END, ', ') INTO v_to FROM unnest(p.roles) r;
    EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, p.tablename);
    v_sql := format('CREATE POLICY %I ON public.%I AS %s FOR %s TO %s', p.policyname, p.tablename, p.permissive, p.cmd, v_to);
    IF p.qual IS NOT NULL THEN v_sql := v_sql || ' USING (' || replace(p.qual,'family_member()','auth_is_family()') || ')'; END IF;
    IF p.with_check IS NOT NULL THEN v_sql := v_sql || ' WITH CHECK (' || replace(p.with_check,'family_member()','auth_is_family()') || ')'; END IF;
    EXECUTE v_sql;
  END LOOP;
  FOR f IN SELECT pr.oid FROM pg_proc pr JOIN pg_namespace n ON n.oid=pr.pronamespace
           WHERE n.nspname='public' AND pr.prokind='f' AND pr.proname LIKE 'family%'
             AND pr.proname <> 'family_member'
             AND pg_get_functiondef(pr.oid) LIKE '%family_member()%' LOOP
    EXECUTE replace(pg_get_functiondef(f.oid), 'family_member()', 'auth_is_family()');
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS public.can_see_family();
DROP FUNCTION IF EXISTS public.family_member();
