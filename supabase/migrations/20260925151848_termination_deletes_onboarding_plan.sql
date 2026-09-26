-- Peter 2026-09-25: a termination deletes the person's onboarding plan.
-- Terminations come only from Peter on the site (edge fn terminate-team-member),
-- which sets team.archived_at. Archived = left, so the plan goes on that change.
-- Steps go with the plan (FK ON DELETE CASCADE); team-card tasks go with their
-- step (trg_onboarding_team_card_tasks). Open plan and group tasks go here.
-- Completed tasks stay as the record of work done, the same rule
-- onboarding_sync_plan uses when a step goes.

CREATE OR REPLACE FUNCTION public.onboarding_delete_plans_for_team(p_team_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_plans uuid[];
  v_n     int := 0;
BEGIN
  SELECT COALESCE(array_agg(p.id), '{}') INTO v_plans
  FROM public.team_onboarding_plans p
  WHERE p.team_member_id = p_team_id
     OR p.candidate_id IN (SELECT hc.id FROM public.hiring_candidates hc
                           WHERE hc.team_member_id = p_team_id);

  IF array_length(v_plans, 1) IS NULL THEN
    RETURN 0;
  END IF;

  DELETE FROM public.tasks t
  USING public.team_onboarding_steps s
  WHERE s.plan_id = ANY (v_plans)
    AND (t.id = s.task_id
         OR (t.related_id = s.id AND t.created_by IN ('onboarding_plan', 'onboarding_group')))
    AND t.status <> 'completed';

  DELETE FROM public.team_onboarding_plans WHERE id = ANY (v_plans);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.onboarding_delete_plans_for_team(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.team_departure_deletes_onboarding_plan()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.onboarding_delete_plans_for_team(NEW.id);
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.team_departure_deletes_onboarding_plan() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_team_departure_deletes_onboarding_plan ON public.team;
CREATE TRIGGER trg_team_departure_deletes_onboarding_plan
AFTER UPDATE OF archived_at ON public.team
FOR EACH ROW
WHEN (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL)
EXECUTE FUNCTION public.team_departure_deletes_onboarding_plan();
