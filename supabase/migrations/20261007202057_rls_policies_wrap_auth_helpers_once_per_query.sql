-- RLS speed: wrap zero-argument auth helpers in policies as ( SELECT fn() ) so Postgres runs them
-- once per query instead of once per row (Supabase RLS performance guidance). Same meaning:
-- none of these functions takes a row value. 2026-10-07, Team page seat profitability ran 9 s as Peter.
DO $rls$
DECLARE p record; pat text := '(?<!SELECT )(?<![.\w])((?:public\.)?(?:is_agency_admin|current_team_member_id|current_app_user_role|auth_is_family|family_is_parent|rpg_can_play)|auth\.(?:uid|jwt|role))\(\)';
  nq text; nw text; sql text; k int := 0;
BEGIN
  FOR p IN SELECT tablename, policyname, qual, with_check FROM pg_policies WHERE schemaname='public' LOOP
    nq := CASE WHEN p.qual IS NULL THEN NULL ELSE regexp_replace(p.qual, pat, '( SELECT \1() )', 'g') END;
    nw := CASE WHEN p.with_check IS NULL THEN NULL ELSE regexp_replace(p.with_check, pat, '( SELECT \1() )', 'g') END;
    IF nq IS DISTINCT FROM p.qual OR nw IS DISTINCT FROM p.with_check THEN
      sql := format('ALTER POLICY %I ON public.%I', p.policyname, p.tablename);
      IF nq IS DISTINCT FROM p.qual THEN sql := sql || ' USING (' || nq || ')'; END IF;
      IF nw IS DISTINCT FROM p.with_check THEN sql := sql || ' WITH CHECK (' || nw || ')'; END IF;
      EXECUTE sql;
      k := k + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'policies rewritten: %', k;
END $rls$;
