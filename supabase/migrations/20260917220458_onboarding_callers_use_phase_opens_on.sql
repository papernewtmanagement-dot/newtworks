-- Point both callers at onboarding_phase_opens_on so the opening date is
-- worked out in exactly one place. Patched off pg_get_functiondef and checked,
-- so nothing else in either function can drift.
DO $mig$
DECLARE v_def text;
BEGIN
  -- 1. the open-step notice
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'onboarding_open_step_notices';

  v_def := replace(v_def,
    'AND CURRENT_DATE >= p.start_date + COALESCE(ph.days_from_start, 0)',
    'AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)');

  IF position('onboarding_phase_opens_on' in v_def) = 0 THEN
    RAISE EXCEPTION 'notice patch did not apply';
  END IF;
  EXECUTE v_def;

  -- 2. the task writer
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'create_onboarding_plan';

  v_def := replace(v_def,
    'SELECT s.id, s.title, s.description, s.assigned_to, ph.name AS phase_name, ph.stage, ph.days_from_start',
    'SELECT s.id, s.title, s.description, s.assigned_to, s.phase, ph.name AS phase_name, ph.stage');

  v_def := replace(v_def,
$old$    v_due := GREATEST(
               CURRENT_DATE,
               COALESCE(p_start_date, CURRENT_DATE) + COALESCE(r.days_from_start, 0)
             );$old$,
$new$    v_due := GREATEST(
               CURRENT_DATE,
               COALESCE(
                 public.onboarding_phase_opens_on(v_agency_id, r.phase, p_start_date),
                 COALESCE(p_start_date, CURRENT_DATE))
             );$new$);

  IF position('onboarding_phase_opens_on' in v_def) = 0 THEN
    RAISE EXCEPTION 'task writer patch did not apply';
  END IF;
  IF position('r.days_from_start' in v_def) > 0 THEN
    RAISE EXCEPTION 'the old flat offset is still in the task writer';
  END IF;
  EXECUTE v_def;
END $mig$;


-- Re-date the live tasks off the chained calculation.
UPDATE public.tasks tk
SET due_date   = GREATEST(CURRENT_DATE,
                   COALESCE(public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date),
                            p.start_date)),
    updated_at = now()
FROM public.team_onboarding_steps s
JOIN public.team_onboarding_plans p ON p.id = s.plan_id
WHERE tk.id = s.task_id
  AND p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND p.status = 'active'
  AND tk.status <> 'completed';


-- Clear the announced stamp on anything whose phase has not opened yet.
UPDATE public.team_onboarding_steps s
SET opened_notified_at = NULL
FROM public.team_onboarding_plans p
WHERE s.plan_id = p.id
  AND p.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND p.status = 'active'
  AND s.completed_at IS NULL
  AND s.opened_notified_at IS NOT NULL
  AND CURRENT_DATE < public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date);
