-- Found by the first run of the Nightly Login Check (login_guard_watcher).

-- 1. Three roleplaying functions from roleplaying_step3_creatures were opened to logins with no login check.
SELECT public.add_login_guard('public.rpg_card_difficulty(numeric)'::regprocedure, 'family');
SELECT public.add_login_guard('public.rpg_creature_list()'::regprocedure, 'family');
SELECT public.add_login_guard('public.rpg_creature_card(uuid)'::regprocedure, 'family');

-- 2. dancers holds only the drawings of the dancing characters, which team and family pages both show
--    (celebrations, done marks, the Inventory list). It is shared like users, agency and manuals, so the
--    audit allows the family login to read it.
CREATE OR REPLACE FUNCTION public.login_guard_audit()
RETURNS TABLE(object text, problem text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  -- The only full-access functions open to logins with no check: the yes/no checks the row rules call.
  -- They answer only about the person signed in.
  SELECT p.oid::regprocedure::text, 'full-access function open to logins with no login check'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc !~ 'public\.require_login\('
    AND p.proname <> ALL (ARRAY['auth_is_family','current_app_user_role','current_team_member_id','family_is_parent','is_agency_admin','onboarding_can_see_plan','onboarding_can_see_step','rp_appt_can_mark','rp_entry_can_change','rp_entry_can_note','rp_issue_can_change','rp_sale_can_edit','rpg_can_play'])
  UNION ALL
  SELECT p.oid::regprocedure::text, 'function open to callers with no login'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
  UNION ALL
  SELECT c.oid::regclass::text, 'full-access view readable by logins with no family block'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false)
    AND has_table_privilege('authenticated', c.oid, 'SELECT')
    AND pg_get_viewdef(c.oid) !~ 'auth_is_family\(\)'
  UNION ALL
  SELECT c.oid::regclass::text, 'full-access view open to writes by logins'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false)
    AND (has_table_privilege('authenticated', c.oid, 'INSERT') OR has_table_privilege('authenticated', c.oid, 'UPDATE')
         OR has_table_privilege('authenticated', c.oid, 'DELETE'))
  UNION ALL
  SELECT c.oid::regclass::text, 'materialized view readable by logins'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'm' AND has_table_privilege('authenticated', c.oid, 'SELECT')
  UNION ALL
  SELECT c.oid::regclass::text, 'table readable by logins with no family block'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
    AND has_table_privilege('authenticated', c.oid, 'SELECT')
    AND c.relname !~ '^(family_|rpg_)' AND c.relname NOT IN ('users','agency','manuals','dancers')
    AND (NOT c.relrowsecurity OR NOT EXISTS (
          SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid AND pol.polname = 'zz_block_family_login'));
$$;

-- 3. Nothing left open.
DO $audit$
BEGIN
  IF EXISTS (SELECT 1 FROM public.login_guard_audit()) THEN
    RAISE EXCEPTION 'audit still finds: %', (SELECT string_agg(object || ' (' || problem || ')', '; ') FROM public.login_guard_audit());
  END IF;
END
$audit$;