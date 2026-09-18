-- The link between an onboarding step and its task only ran one way. Ticking
-- the step updated the task; ticking the task did nothing to the step, so
-- Alvi could clear her whole task list and the onboarding checklist would
-- still show every item outstanding.
--
-- This closes it. Completing the task completes the step, and reopening the
-- task reopens the step.
--
-- Two kinds of step are deliberately left alone:
--   * a step that fills itself in (auto_source set, like references) — the
--     evidence decides those, not a checkbox
--   * a step with sub-items still open — onboarding_step_complete_gate would
--     refuse it, and a refusal here would abort the person's task update
CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE s record; v_open_subs int;
BEGIN
  IF NEW.related_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT id, completed_at, auto_source, substeps, substeps_done
  INTO s
  FROM public.team_onboarding_steps
  WHERE id = NEW.related_id;

  IF NOT FOUND OR s.auto_source IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND s.completed_at IS NULL THEN
    SELECT count(*) INTO v_open_subs
    FROM jsonb_array_elements(COALESCE(s.substeps, '[]'::jsonb)) sub
    WHERE NOT COALESCE(s.substeps_done, '[]'::jsonb) @> jsonb_build_array(sub);

    IF COALESCE(v_open_subs, 0) > 0 THEN
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

DROP TRIGGER IF EXISTS trg_task_tick_syncs_onboarding_step ON public.tasks;
CREATE TRIGGER trg_task_tick_syncs_onboarding_step
  AFTER UPDATE OF status ON public.tasks
  FOR EACH ROW
  WHEN (NEW.created_by = 'onboarding_plan')
  EXECUTE FUNCTION public.task_tick_syncs_onboarding_step();
