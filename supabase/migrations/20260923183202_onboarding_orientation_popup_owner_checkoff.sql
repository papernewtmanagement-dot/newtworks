-- Peter 2026-09-23: Orientation is a pop-up only he opens, from an (i) on the Orientation card. At the bottom he
-- checks off each new hire who was there, which checks off Orientation on that hire's plan. New hires cannot check
-- it off themselves. widget 'orientation' marks the card. Its sub-items are Peter's talking points in the pop-up,
-- not a checklist, so they never have to be ticked before the card can be.

ALTER TABLE public.onboarding_step_templates
  DROP CONSTRAINT IF EXISTS onboarding_step_templates_widget_chk,
  ADD CONSTRAINT onboarding_step_templates_widget_chk CHECK (widget IS NULL OR widget IN ('team_forms', 'orientation'));
ALTER TABLE public.team_onboarding_steps
  DROP CONSTRAINT IF EXISTS team_onboarding_steps_widget_chk,
  ADD CONSTRAINT team_onboarding_steps_widget_chk CHECK (widget IS NULL OR widget IN ('team_forms', 'orientation'));

-- The one rule for whether a card's sub-items must all be ticked before the card can be.
-- The app mirrors it with subItemsRequired() in src/lib/onboardingUi.jsx.
CREATE OR REPLACE FUNCTION public.onboarding_subitems_required(p_widget text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_widget IS DISTINCT FROM 'orientation';
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_missing int;
BEGIN
  -- Orientation is checked off by Peter at orientation, from its pop-up or his task. Nobody else can check it
  -- off or undo it. Work with nobody signed in (the template sync, a migration) is not a person ticking a box.
  IF NEW.widget = 'orientation'
     AND auth.uid() IS NOT NULL
     AND COALESCE(public.current_app_user_role(), '') <> 'owner' THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Peter checks off Orientation at orientation.';
      END IF;
    ELSIF NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
      RAISE EXCEPTION 'Peter checks off Orientation at orientation.';
    END IF;
  END IF;

  -- Only guard the moment a step goes from open to done.
  IF NEW.completed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.auto_source IS NOT NULL
     AND COALESCE(current_setting('app.onboarding_autotick', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This step fills itself in from the rest of Newtworks. It cannot be ticked by hand.';
  END IF;

  IF NEW.unlocks_on IS NOT NULL
     AND NEW.unlocks_on > (now() AT TIME ZONE 'America/Chicago')::date THEN
    RAISE EXCEPTION 'This step opens on %.', to_char(NEW.unlocks_on, 'Dy Mon FMDD');
  END IF;

  IF NOT public.onboarding_subitems_required(NEW.widget)
     OR array_length(public.onboarding_substep_labels(NEW.substeps), 1) IS NULL THEN
    RETURN NEW;
  END IF;

  v_missing := public.onboarding_substeps_missing(NEW.substeps, NEW.substeps_done);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all the sub-items first. % still open.', v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_label text;
BEGIN
  IF NEW.related_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT id, completed_at, auto_source, substeps, substeps_done, owner_kind, widget
  INTO s
  FROM public.team_onboarding_steps
  WHERE id = NEW.related_id;

  IF NOT FOUND OR s.auto_source IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Team card: this task is one teammate's own line on it.
  IF s.owner_kind = 'team' THEN
    SELECT public.onboarding_team_label(tm) INTO v_label
    FROM public.users u JOIN public.team tm ON tm.id = u.team_member_id
    WHERE u.id = NEW.assigned_to;
    IF v_label IS NULL OR NOT (v_label = ANY (public.onboarding_substep_labels(s.substeps))) THEN
      RETURN NEW;
    END IF;
    IF NEW.status = 'completed' THEN
      UPDATE public.team_onboarding_steps
      SET substeps_done = COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb)
                          || jsonb_build_array(v_label),
          updated_at = now()
      WHERE id = s.id
        AND NOT (COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb) ? v_label);
      UPDATE public.team_onboarding_steps
      SET completed_at = now(), completed_by = COALESCE(completed_by, NEW.assigned_to), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL
        AND public.onboarding_substeps_missing(substeps, substeps_done) = 0;
    ELSE
      UPDATE public.team_onboarding_steps
      SET substeps_done = substeps_done - v_label,
          completed_at  = NULL,
          completed_by  = NULL,
          updated_at    = now()
      WHERE id = s.id AND jsonb_typeof(substeps_done) = 'array' AND substeps_done ? v_label;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND s.completed_at IS NULL THEN
    IF public.onboarding_subitems_required(s.widget)
       AND public.onboarding_substeps_missing(s.substeps, s.substeps_done) > 0 THEN
      RETURN NEW;   -- sub-items still open; the checklist stays the record
    END IF;

    UPDATE public.team_onboarding_steps
    SET completed_at = now(),
        completed_by = COALESCE(completed_by, NEW.assigned_to),
        updated_at   = now()
    WHERE id = s.id;

  ELSIF NEW.status <> 'completed' AND s.completed_at IS NOT NULL THEN
    UPDATE public.team_onboarding_steps
    SET completed_at = NULL,
        completed_by = NULL,
        updated_at   = now()
    WHERE id = s.id;
  END IF;

  RETURN NEW;
END;
$function$;

UPDATE public.onboarding_step_templates SET widget = 'orientation'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_orientation_page';
