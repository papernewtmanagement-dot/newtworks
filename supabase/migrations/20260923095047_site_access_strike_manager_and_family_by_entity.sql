-- Site access levels: strike "manager". Site admin access level is now "admin".
-- Family and Course: site admins, the family login, and team members in the
-- Personal, PaperNewt LLC or Steward entity. Non-admins all get the same access.

-- 1. users.role: manager -> admin
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
UPDATE public.users SET role = 'admin' WHERE role = 'manager';
ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role = ANY (ARRAY['owner','admin','staff','readonly','accountant','family']));

-- 2. Rebuild every policy that named 'manager' (text + policy name)
DO $$
DECLARE p record; v_to text; v_sql text;
BEGIN
  FOR p IN SELECT * FROM pg_policies WHERE schemaname='public'
           AND (qual LIKE '%''manager''%' OR with_check LIKE '%''manager''%') LOOP
    SELECT string_agg(CASE WHEN r='public' THEN 'public' ELSE quote_ident(r) END, ', ') INTO v_to FROM unnest(p.roles) r;
    EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, p.tablename);
    v_sql := format('CREATE POLICY %I ON public.%I AS %s FOR %s TO %s',
      replace(p.policyname,'manager','admin'), p.tablename, p.permissive, p.cmd, v_to);
    IF p.qual IS NOT NULL THEN v_sql := v_sql || ' USING (' || replace(p.qual,'''manager''','''admin''') || ')'; END IF;
    IF p.with_check IS NOT NULL THEN v_sql := v_sql || ' WITH CHECK (' || replace(p.with_check,'''manager''','''admin''') || ')'; END IF;
    EXECUTE v_sql;
  END LOOP;
END $$;

-- 3. Functions that checked 'manager' as an access level (rp_add_note's 'Manager' is a display word, untouched)
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.prokind='f' AND pg_get_functiondef(p.oid) LIKE '%''manager''%' LOOP
    EXECUTE replace(pg_get_functiondef(f.oid), '''manager''', '''admin''');
  END LOOP;
END $$;

-- 4. Family access
CREATE OR REPLACE FUNCTION public.family_is_parent()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_agency_admin();
$$;

CREATE OR REPLACE FUNCTION public.family_member()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.auth_user_id = auth.uid()
      AND (u.role = 'family'
           OR EXISTS (SELECT 1 FROM public.team t
                      JOIN public.business_entities be ON be.id = t.business_entity_id
                      WHERE t.user_id = u.id AND be.slug IN ('personal','papernewt','steward')))
  );
$$;

CREATE OR REPLACE FUNCTION public.can_see_family()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_agency_admin() OR public.family_member();
$$;
GRANT EXECUTE ON FUNCTION public.family_member(), public.can_see_family() TO authenticated;

DO $$
DECLARE p record; v_to text; v_sql text; f record;
BEGIN
  FOR p IN SELECT * FROM pg_policies WHERE schemaname='public' AND tablename LIKE 'family%'
           AND (qual LIKE '%auth_is_family()%' OR with_check LIKE '%auth_is_family()%') LOOP
    SELECT string_agg(CASE WHEN r='public' THEN 'public' ELSE quote_ident(r) END, ', ') INTO v_to FROM unnest(p.roles) r;
    EXECUTE format('DROP POLICY %I ON public.%I', p.policyname, p.tablename);
    v_sql := format('CREATE POLICY %I ON public.%I AS %s FOR %s TO %s', p.policyname, p.tablename, p.permissive, p.cmd, v_to);
    IF p.qual IS NOT NULL THEN v_sql := v_sql || ' USING (' || replace(p.qual,'auth_is_family()','family_member()') || ')'; END IF;
    IF p.with_check IS NOT NULL THEN v_sql := v_sql || ' WITH CHECK (' || replace(p.with_check,'auth_is_family()','family_member()') || ')'; END IF;
    EXECUTE v_sql;
  END LOOP;
  FOR f IN SELECT pr.oid FROM pg_proc pr JOIN pg_namespace n ON n.oid=pr.pronamespace
           WHERE n.nspname='public' AND pr.prokind='f' AND pr.proname LIKE 'family%'
             AND pg_get_functiondef(pr.oid) LIKE '%auth_is_family()%' LOOP
    EXECUTE replace(pg_get_functiondef(f.oid), 'auth_is_family()', 'family_member()');
  END LOOP;
END $$;
