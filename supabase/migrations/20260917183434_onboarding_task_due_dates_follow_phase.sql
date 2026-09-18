-- create_onboarding_plan gave every ramp task the start date, so Bryson's
-- seven tasks were all due the day he started, including the ones for week
-- fourteen. The due date now follows the phase, read from the same
-- onboarding_phases.days_from_start the open-step notice uses.
--
-- Patched in place off pg_get_functiondef rather than retyped, so the rest of
-- the function cannot drift. Both replacements are checked before the new
-- definition is executed.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_onboarding_plan';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'create_onboarding_plan not found';
  END IF;

  v_def := replace(v_def,
    'SELECT s.id, s.title, s.description, s.assigned_to, ph.name AS phase_name, ph.stage',
    'SELECT s.id, s.title, s.description, s.assigned_to, ph.name AS phase_name, ph.stage, ph.days_from_start');

  v_def := replace(v_def,
$old$    v_due := CASE
      WHEN r.stage IN ('offer','pre_start') THEN GREATEST(CURRENT_DATE, COALESCE(p_start_date, CURRENT_DATE) - 1)
      ELSE COALESCE(p_start_date, CURRENT_DATE)
    END;$old$,
$new$    -- Due when the phase opens, not when the person starts. Pre-start work
    -- carries a negative offset and lands on today. Week-five work lands in
    -- week five, so a task list is not a wall of things all due on day one.
    v_due := GREATEST(
               CURRENT_DATE,
               COALESCE(p_start_date, CURRENT_DATE) + COALESCE(r.days_from_start, 0)
             );$new$);

  IF position('ph.days_from_start' in v_def) = 0 THEN
    RAISE EXCEPTION 'phase offset was not added to the step query';
  END IF;
  IF position('WHEN r.stage IN' in v_def) > 0 THEN
    RAISE EXCEPTION 'the old due-date branch is still there';
  END IF;

  EXECUTE v_def;
END $mig$;


-- Put the existing tasks right. Bryson's seven were all dated the day he
-- started; they now carry the date their phase opens.
UPDATE public.tasks tk
SET due_date   = GREATEST(CURRENT_DATE, p.start_date + COALESCE(ph.days_from_start, 0)),
    updated_at = now()
FROM public.team_onboarding_steps s
JOIN public.team_onboarding_plans p ON p.id = s.plan_id
LEFT JOIN public.onboarding_phases ph
  ON ph.agency_id = p.agency_id AND ph.phase = s.phase
WHERE tk.id = s.task_id
  AND p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND p.status = 'active'
  AND tk.status <> 'completed';


-- Three of the four steps in the notice I sent Alvi were not due for a
-- fortnight or more. Clear their announced stamp so they are announced when
-- their phase actually opens.
UPDATE public.team_onboarding_steps s
SET opened_notified_at = NULL
FROM public.team_onboarding_plans p,
     public.onboarding_phases ph
WHERE s.plan_id = p.id
  AND ph.agency_id = p.agency_id AND ph.phase = s.phase
  AND p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND p.status = 'active'
  AND s.completed_at IS NULL
  AND s.opened_notified_at IS NOT NULL
  AND CURRENT_DATE < p.start_date + COALESCE(ph.days_from_start, 0);
