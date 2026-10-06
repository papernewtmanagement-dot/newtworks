-- Peter 2026-10-05: (1) the salaried Account Manager decision is Peter's own
-- card closing week 13; (2) every step has a due date, so the plan can gather
-- what is late into one Overdue card.

-- The last day a step can be done on time. Before Start: the day before the
-- start date. A weekly card (and Setup, which runs inside week 1): the last day
-- of its week. Never before the step itself opens.
CREATE OR REPLACE FUNCTION public.onboarding_step_deadline(p_agency_id uuid, p_phase integer, p_start date, p_unlocks_on date)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_start IS NULL THEN NULL
           WHEN ph.stage = 'pre_start' THEN p_start - 1
           WHEN ph.stage = 'ramp' THEN GREATEST(
             public.onboarding_phase_opens_on(p_agency_id, p_phase, p_start) + 7 * GREATEST(COALESCE(ph.weeks_long, 0), 1) - 1,
             COALESCE(p_unlocks_on, p_start))
         END
  FROM public.onboarding_phases ph
  WHERE ph.agency_id = p_agency_id AND ph.phase = p_phase;
$function$;

ALTER TABLE public.team_onboarding_steps ADD COLUMN IF NOT EXISTS due_on date;

CREATE OR REPLACE FUNCTION public.tg_onboarding_step_due_on()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  SELECT public.onboarding_step_deadline(p.agency_id, NEW.phase, p.start_date, NEW.unlocks_on)
  INTO NEW.due_on
  FROM public.team_onboarding_plans p WHERE p.id = NEW.plan_id;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_onboarding_step_due_on ON public.team_onboarding_steps;
CREATE TRIGGER trg_onboarding_step_due_on
  BEFORE INSERT OR UPDATE OF phase, unlocks_on, plan_id ON public.team_onboarding_steps
  FOR EACH ROW EXECUTE FUNCTION public.tg_onboarding_step_due_on();

-- A moved start date moves every due date on the plan.
CREATE OR REPLACE FUNCTION public.tg_onboarding_plan_start_moved()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.team_onboarding_steps s
  SET due_on = public.onboarding_step_deadline(NEW.agency_id, s.phase, NEW.start_date, s.unlocks_on)
  WHERE s.plan_id = NEW.id;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_onboarding_plan_start_moved ON public.team_onboarding_plans;
CREATE TRIGGER trg_onboarding_plan_start_moved
  AFTER UPDATE OF start_date ON public.team_onboarding_plans
  FOR EACH ROW WHEN (OLD.start_date IS DISTINCT FROM NEW.start_date)
  EXECUTE FUNCTION public.tg_onboarding_plan_start_moved();

-- Fill in every existing step.
UPDATE public.team_onboarding_steps s
SET due_on = public.onboarding_step_deadline(p.agency_id, s.phase, p.start_date, s.unlocks_on)
FROM public.team_onboarding_plans p
WHERE p.id = s.plan_id;

-- The decision moves off the new hire's End of Week 13 card onto Peter's own
-- card, closing week 13. Same line and the same pass rule under its (i).
INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category, is_required, sort_order, is_active,
   substeps, owner_kind, assigned_to, track, track_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', 't_week13_salaried_decision', 'Salaried Account Manager Decision',
  'End of week 13: move them to salaried Account Manager, or keep them hourly until they are ready.',
  70, 'training', true, 90, true,
  jsonb_build_array(jsonb_build_object('group', NULL,
    'items', jsonb_build_array('Decide on fulltime/salaried status'),
    'item_info', jsonb_build_object('Decide on fulltime/salaried status',
      t.substeps->0->'item_info'->'Decide on fulltime/salaried status'))),
  'admin', '67f7287d-7110-405f-a7bd-4db433e6d17f', 'Basics', 0
FROM public.onboarding_step_templates t
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'wk70_5_end_of_week_13_s'
  AND NOT EXISTS (SELECT 1 FROM public.onboarding_step_templates x
                  WHERE x.agency_id = t.agency_id AND x.template_key = 't_week13_salaried_decision');

UPDATE public.onboarding_step_templates t
SET substeps = jsonb_set(
      jsonb_set(t.substeps, '{0,items}',
        (SELECT jsonb_agg(i ORDER BY o) FROM jsonb_array_elements(t.substeps->0->'items') WITH ORDINALITY e(i, o)
         WHERE i #>> '{}' <> 'Decide on fulltime/salaried status')),
      '{0,item_info}', (t.substeps->0->'item_info') - 'Decide on fulltime/salaried status'),
    updated_at = now()
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'wk70_5_end_of_week_13_s'
  AND t.substeps->0->'items' ? 'Decide on fulltime/salaried status';

SELECT public.onboarding_sync_plan(p.id)
FROM public.team_onboarding_plans p
WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.status IN ('active','paused');
