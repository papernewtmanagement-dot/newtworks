-- Who can see an onboarding card (Peter 2026-09-21):
--   * Admins (owner, manager) see every card on every plan.
--   * The person the plan is for sees every card from Day 1 forward
--     (phases whose stage is 'ramp'). Offer and pre-start cards stay hidden
--     from them, which keeps their own reference write-ups out of view.
--   * Anyone a card is assigned to sees that card. A references card counts
--     as assigned to whoever is calling that candidate's references.
-- One function decides this. Every policy below calls it.

CREATE OR REPLACE FUNCTION public.onboarding_can_see_step(
  p_plan_id uuid, p_phase integer, p_assigned_to uuid, p_auto_source text)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid; v_agency uuid;
  pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;

  SELECT p.agency_id, p.team_member_id, p.candidate_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;

  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NULL THEN RETURN false; END IF;

  IF p_assigned_to = v_me THEN RETURN true; END IF;

  IF p_auto_source = 'references' AND pl.candidate_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.hiring_reference_callers(pl.candidate_id) k
                 WHERE k.team_member_id = v_me) THEN
    RETURN true;
  END IF;

  IF pl.team_member_id = v_me AND EXISTS (
       SELECT 1 FROM public.onboarding_phases ph
       WHERE ph.agency_id = pl.agency_id AND ph.phase = p_phase AND ph.stage = 'ramp') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

-- A plan shows up for anyone who can see at least one card on it, plus the
-- person it is for and admins.
CREATE OR REPLACE FUNCTION public.onboarding_can_see_plan(p_plan_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_me uuid; v_agency uuid; pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  SELECT p.agency_id, p.team_member_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;
  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NOT NULL AND pl.team_member_id = v_me THEN RETURN true; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.team_onboarding_steps s
    WHERE s.plan_id = p_plan_id
      AND public.onboarding_can_see_step(s.plan_id, s.phase, s.assigned_to, s.auto_source));
END;
$function$;

-- Names of the people on the plans this person can see. Candidates are
-- admin-only in hiring_candidates, so a teammate working a card would
-- otherwise see "Candidate" instead of a name.
CREATE OR REPLACE FUNCTION public.onboarding_visible_plan_names()
RETURNS TABLE(plan_id uuid, subject_name text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT p.id,
         COALESCE(
           NULLIF(TRIM(COALESCE(NULLIF(t.nickname,''), t.first_name, '') || ' ' || COALESCE(t.last_name,'')), ''),
           NULLIF(TRIM(COALESCE(hc.first_name,'') || ' ' || COALESCE(hc.last_name,'')), ''),
           hc.candidate_name, 'New hire')
  FROM public.team_onboarding_plans p
  LEFT JOIN public.team t ON t.id = p.team_member_id
  LEFT JOIN public.hiring_candidates hc ON hc.id = p.candidate_id
  WHERE public.onboarding_can_see_plan(p.id);
$function$;

REVOKE ALL ON FUNCTION public.onboarding_can_see_step(uuid, integer, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.onboarding_can_see_plan(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.onboarding_visible_plan_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_can_see_step(uuid, integer, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.onboarding_can_see_plan(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.onboarding_visible_plan_names() TO authenticated;

-- Plans: read
DROP POLICY IF EXISTS top_select ON public.team_onboarding_plans;
CREATE POLICY top_select ON public.team_onboarding_plans
  FOR SELECT TO authenticated
  USING (public.onboarding_can_see_plan(id));

-- Steps: read and update follow the same rule. Insert and delete stay admin.
DROP POLICY IF EXISTS tos_select ON public.team_onboarding_steps;
DROP POLICY IF EXISTS tos_select_assignee ON public.team_onboarding_steps;
DROP POLICY IF EXISTS tos_update_assignee ON public.team_onboarding_steps;
DROP POLICY IF EXISTS tos_update_self_or_admin ON public.team_onboarding_steps;

CREATE POLICY tos_select ON public.team_onboarding_steps
  FOR SELECT TO authenticated
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source));

CREATE POLICY tos_update ON public.team_onboarding_steps
  FOR UPDATE TO authenticated
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source))
  WITH CHECK (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source));
