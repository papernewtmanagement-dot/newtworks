-- Put back the security setting the 20260921181948 view rewrite dropped
-- (first set in 20260915225142): the view runs as the person reading it.
ALTER VIEW public.v_team_form_status SET (security_invoker = true);

-- Every new team row gets its onboarding plan the moment it is created, however
-- it was created: Add Member on the Team page, or offer acceptance. If an open
-- candidate with the same personal email exists, the team row is linked to it
-- first, so a plan started at the candidate stage is attached, not duplicated.
CREATE OR REPLACE FUNCTION public.team_after_insert_link_and_plan()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_cand uuid;
BEGIN
  IF NEW.archived_at IS NOT NULL OR COALESCE(NEW.is_test_user, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.email_personal IS NOT NULL THEN
    SELECT hc.id INTO v_cand
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = NEW.agency_id
      AND lower(btrim(hc.email)) = lower(btrim(NEW.email_personal))
      AND (hc.team_member_id IS NULL OR hc.team_member_id = NEW.id)
      AND hc.status NOT IN ('declined', 'former')
    ORDER BY hc.updated_at DESC
    LIMIT 1;

    IF v_cand IS NOT NULL THEN
      UPDATE public.hiring_candidates
         SET team_member_id = NEW.id, updated_at = now()
       WHERE id = v_cand AND team_member_id IS NULL;
    END IF;
  END IF;

  PERFORM public.onboarding_ensure_plan_for_team_member(NEW.id, v_cand);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_team_after_insert_link_and_plan ON public.team;
CREATE TRIGGER trg_team_after_insert_link_and_plan
  AFTER INSERT ON public.team
  FOR EACH ROW EXECUTE FUNCTION public.team_after_insert_link_and_plan();

-- The trigger now covers offer acceptance too, so the explicit call added to
-- hiring_accept_offer earlier today comes back out (one place, not two).
DO $mig$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.hiring_accept_offer'::regproc);
  IF position('onboarding_ensure_plan_for_team_member' in v_def) > 0 THEN
    v_def := replace(v_def,
      E'\n  -- Their onboarding plan, attached from the candidate stage or built new.\n  PERFORM public.onboarding_ensure_plan_for_team_member(v_team, c.id);\n',
      E'');
    IF position('onboarding_ensure_plan_for_team_member' in v_def) > 0 THEN
      RAISE EXCEPTION 'hiring_accept_offer: could not remove the explicit plan call';
    END IF;
    EXECUTE v_def;
  END IF;
END
$mig$;
