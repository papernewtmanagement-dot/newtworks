-- Peter 2026-09-23: the Jabber card's team list uses each person's full name as it appears in their State Farm email,
-- which is how Jabber finds them. The team lists on Agent Tech Setup and Team Adds the New Hire leave Alvi off.
-- Also fixed: a team-list group's own lines (the *Park line under *Office on Jabber) were dropped on plans. The names
-- now come first and the group's own lines follow, the way the template shows them.
-- And: someone taken off a team card's list now loses their open task for it (Alvi's Team Adds the New Hire task).
SELECT set_config('app.onboarding_template_sync', 'off', true);

ALTER TABLE public.team ADD COLUMN IF NOT EXISTS onboarding_office_list boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.team.onboarding_office_list IS
  'false = left off the office team lists on onboarding cards (Agent Tech Setup, Team Adds the New Hire). The Jabber list, which comes from State Farm emails, still includes them.';

-- The one rule for a name from a State Farm email: first.last.alias@statefarm.com -> First Last.
CREATE OR REPLACE FUNCTION public.team_sf_email_name(p_email text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(initcap(array_to_string(
           CASE WHEN array_length(parts, 1) >= 3 THEN parts[1:array_length(parts, 1) - 1] ELSE parts END, ' ')), '')
  FROM (SELECT string_to_array(lower(split_part(trim(p_email), '@', 1)), '.') AS parts) s
  WHERE p_email IS NOT NULL AND position('@' in p_email) > 1;
$function$;
REVOKE ALL ON FUNCTION public.team_sf_email_name(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_sf_email_name(text) TO authenticated, service_role;

-- New kind argument, so the old two-argument version goes first.
DROP FUNCTION IF EXISTS public.onboarding_team_list_names(uuid, uuid);
CREATE FUNCTION public.onboarding_team_list_names(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_exclude_team_id uuid DEFAULT NULL::uuid,
  p_kind text DEFAULT 'office')
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
SELECT public.require_login('staff');
  -- Who is on an onboarding team list, named the way the card needs.
  -- office:   how the office knows them (nickname), minus anyone marked off the office lists.
  -- sf_email: the full name in their State Farm email, which is how Jabber finds them.
  SELECT COALESCE(array_agg(n ORDER BY n), ARRAY[]::text[])
  FROM (
    SELECT DISTINCT CASE WHEN p_kind = 'sf_email'
             THEN COALESCE(public.team_sf_email_name(tm.email_sf), public.onboarding_team_label(tm))
             ELSE public.onboarding_team_label(tm) END AS n
    FROM public.team tm
    WHERE tm.agency_id = p_agency_id
      AND tm.category = 'agency'
      AND tm.is_active IS TRUE
      AND tm.archived_at IS NULL
      AND COALESCE(tm.is_test_user, false) = false
      AND tm.id IS DISTINCT FROM p_exclude_team_id
      AND (p_kind = 'sf_email' OR tm.onboarding_office_list)
  ) x
  WHERE n IS NOT NULL;
$function$;
REVOKE ALL ON FUNCTION public.onboarding_team_list_names(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_team_list_names(uuid, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.onboarding_fill_substeps(p_substeps jsonb, p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- A group marked fill gets the team's names first, then its own lines, as the template shows them.
  -- team_list = the office list; team_list_sf = full names from State Farm emails (Jabber).
  SELECT CASE
    WHEN jsonb_typeof(p_substeps) <> 'array' OR p_substeps IS NULL THEN p_substeps
    WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_substeps) e
                     WHERE jsonb_typeof(e) = 'object' AND e ->> 'fill' IN ('team_list', 'team_list_sf')) THEN p_substeps
    ELSE (
      SELECT jsonb_agg(
               CASE WHEN jsonb_typeof(e) = 'object' AND e ->> 'fill' IN ('team_list', 'team_list_sf')
                    THEN jsonb_set(e, '{items}',
                           COALESCE(to_jsonb((SELECT public.onboarding_team_list_names(p.agency_id, p.team_member_id,
                                                        CASE WHEN e ->> 'fill' = 'team_list_sf' THEN 'sf_email' ELSE 'office' END)
                                              FROM public.team_onboarding_plans p WHERE p.id = p_plan_id)), '[]'::jsonb)
                           || CASE WHEN jsonb_typeof(e -> 'items') = 'array' THEN e -> 'items' ELSE '[]'::jsonb END)
                    ELSE e END
               ORDER BY ord)
      FROM jsonb_array_elements(p_substeps) WITH ORDINALITY AS x(e, ord)
    )
  END;
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_team_card_tasks_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.tasks WHERE related_id = OLD.id AND created_by = 'onboarding_team_card';
    RETURN OLD;
  END IF;
  IF NEW.owner_kind IS DISTINCT FROM 'team' THEN RETURN NEW; END IF;

  -- Someone taken off the card's list loses their open task for it.
  DELETE FROM public.tasks k
  USING public.users u, public.team tm
  WHERE k.related_id = NEW.id AND k.created_by = 'onboarding_team_card' AND k.status <> 'completed'
    AND u.id = k.assigned_to AND tm.id = u.team_member_id
    AND NOT (COALESCE(public.onboarding_team_label(tm), '') = ANY (public.onboarding_substep_labels(NEW.substeps)));

  UPDATE public.tasks t
  SET status       = CASE WHEN x.done THEN 'completed' ELSE 'open' END,
      completed_at = CASE WHEN x.done THEN now() ELSE NULL END,
      updated_at   = now()
  FROM (
    SELECT k.id,
           (NEW.completed_at IS NOT NULL
            OR public.onboarding_team_label(tm) = ANY (public.onboarding_substep_labels(
                 CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ELSE '[]'::jsonb END))) AS done
    FROM public.tasks k
    JOIN public.users u ON u.id = k.assigned_to
    JOIN public.team tm ON tm.id = u.team_member_id
    WHERE k.related_id = NEW.id AND k.created_by = 'onboarding_team_card'
  ) x
  WHERE t.id = x.id
    AND (t.status = 'completed') IS DISTINCT FROM x.done;

  RETURN NEW;
END;
$function$;

-- A change to someone's State Farm email or office-list flag re-syncs the plans too.
DROP TRIGGER IF EXISTS trg_team_onboarding_team_list ON public.team;
CREATE TRIGGER trg_team_onboarding_team_list
  AFTER INSERT OR DELETE OR UPDATE OF first_name, last_name, nickname, email_sf, onboarding_office_list,
    is_active, archived_at, is_test_user, category, role_category
  ON public.team FOR EACH STATEMENT EXECUTE FUNCTION onboarding_templates_changed();

-- Jabber's *Office list comes from State Farm emails.
UPDATE public.onboarding_step_templates t
   SET substeps = (SELECT jsonb_agg(CASE WHEN jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list'
                                         THEN jsonb_set(e, '{fill}', '"team_list_sf"') ELSE e END ORDER BY ord)
                   FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord))
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_jabber';

-- Alvi off the office lists.
UPDATE public.team SET onboarding_office_list = false WHERE id = 'd7431075-d29f-4833-9503-430945894b04';

SELECT set_config('app.onboarding_template_sync', '', true);
SELECT public.onboarding_sync_open_plans('126794dd-25ff-47d2-a436-724499733365');
