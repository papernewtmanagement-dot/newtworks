-- Onboarding 2026-09-22 (Peter): steps that open on the Friday before start,
-- an "archived process instead" alternative inside a card, and one Peter.
--
-- 1) unlock_rule on templates and steps. 'friday_before_start' keeps a step
--    locked until the Friday before the plan's start date. The date is worked
--    out in ONE place, onboarding_unlock_date(), and stored on the step as
--    unlocks_on by onboarding_sync_plan() so the page, the gate, the notices
--    and the task due date all read the same value.
-- 2) A sub-item group can carry alt_for = '<label>'. It is a second way to do
--    that one line. The line counts as done when it is ticked OR when every
--    item in the alternative group is ticked. onboarding_substeps_missing() is
--    the one place that rule lives in the database.

ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS unlock_rule text;
ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS unlock_rule text,
  ADD COLUMN IF NOT EXISTS unlocks_on  date;

ALTER TABLE public.onboarding_step_templates
  DROP CONSTRAINT IF EXISTS onboarding_step_templates_unlock_rule_chk;
ALTER TABLE public.onboarding_step_templates
  ADD CONSTRAINT onboarding_step_templates_unlock_rule_chk
  CHECK (unlock_rule IS NULL OR unlock_rule IN ('friday_before_start'));
ALTER TABLE public.team_onboarding_steps
  DROP CONSTRAINT IF EXISTS team_onboarding_steps_unlock_rule_chk;
ALTER TABLE public.team_onboarding_steps
  ADD CONSTRAINT team_onboarding_steps_unlock_rule_chk
  CHECK (unlock_rule IS NULL OR unlock_rule IN ('friday_before_start'));

-- The Friday strictly before the start date. Monday start -> the Friday 3 days
-- earlier; Friday start -> the Friday a week earlier.
CREATE OR REPLACE FUNCTION public.onboarding_unlock_date(p_rule text, p_start date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_rule = 'friday_before_start' AND p_start IS NOT NULL
             THEN p_start - (((EXTRACT(DOW FROM p_start)::int + 1) % 7) + 1)
         END;
$$;

-- How many sub-items still stand between a step and done.
CREATE OR REPLACE FUNCTION public.onboarding_substeps_missing(p_substeps jsonb, p_done jsonb)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  WITH g AS (
    SELECT e
    FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(p_substeps) = 'array' THEN p_substeps ELSE '[]'::jsonb END) e
  ),
  done AS (
    SELECT public.onboarding_substep_labels(
             CASE WHEN jsonb_typeof(p_done) = 'array' THEN p_done ELSE '[]'::jsonb END) AS d
  ),
  req AS (
    SELECT e #>> '{}' AS l FROM g WHERE jsonb_typeof(e) = 'string'
    UNION ALL
    SELECT i #>> '{}'
    FROM g, LATERAL jsonb_array_elements(e -> 'items') i
    WHERE jsonb_typeof(e) = 'object'
      AND jsonb_typeof(e -> 'items') = 'array'
      AND NULLIF(e ->> 'alt_for', '') IS NULL
      AND jsonb_typeof(i) = 'string'
  ),
  alts AS (
    SELECT e ->> 'alt_for' AS alt_for,
           public.onboarding_substep_labels(e -> 'items') AS items
    FROM g
    WHERE jsonb_typeof(e) = 'object' AND NULLIF(e ->> 'alt_for', '') IS NOT NULL
  )
  SELECT count(*)::int
  FROM req, done
  WHERE NOT (req.l = ANY (done.d))
    AND NOT EXISTS (
      SELECT 1 FROM alts a
      WHERE a.alt_for = req.l
        AND array_length(a.items, 1) IS NOT NULL
        AND a.items <@ done.d);
$$;

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_missing int;
BEGIN
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

  IF array_length(public.onboarding_substep_labels(NEW.substeps), 1) IS NULL THEN
    RETURN NEW;
  END IF;

  v_missing := public.onboarding_substeps_missing(NEW.substeps, NEW.substeps_done);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all the sub-items first. % still open.', v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

-- Peter is "the agent" in the template. His team record is the owner's.
CREATE OR REPLACE FUNCTION public.onboarding_agent_team_id(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT u.team_member_id
  FROM public.users u
  WHERE u.agency_id = p_agency_id AND u.role = 'owner' AND u.team_member_id IS NOT NULL
  ORDER BY u.created_at
  LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION public.onboarding_agent_team_id(uuid) TO authenticated;

-- onboarding_sync_plan: carry unlock_rule, keep unlocks_on current, and date the
-- task off unlocks_on when a step has one. Patched off the live definition and
-- checked so nothing else in the function drifts.
DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_new := v_def;

  v_new := replace(v_new,
$a$  WHERE s.plan_id = p_plan_id AND s.phase IS DISTINCT FROM t.phase;$a$,
$b$  WHERE s.plan_id = p_plan_id
    AND (s.phase IS DISTINCT FROM t.phase
         OR s.unlocks_on IS DISTINCT FROM public.onboarding_unlock_date(t.unlock_rule, p.start_date));$b$);

  v_new := replace(v_new,
$a$    substeps, substeps_done, owner_kind, assigned_to, track, blocked_by, track_order, auto_source
  )$a$,
$b$    substeps, substeps_done, owner_kind, assigned_to, track, blocked_by, track_order, auto_source,
    unlock_rule, unlocks_on
  )$b$);

  v_new := replace(v_new,
$a$    t.owner_kind, t.assigned_to, t.track, t.blocked_by, t.track_order, t.auto_source
  FROM public.onboarding_templates_for_plan(p_plan_id) t$a$,
$b$    t.owner_kind, t.assigned_to, t.track, t.blocked_by, t.track_order, t.auto_source,
    t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date)
  FROM public.onboarding_templates_for_plan(p_plan_id) t$b$);

  v_new := replace(v_new,
$a$      auto_source           = t.auto_source,
      required_topic_set_id = t.required_topic_set_id,$a$,
$b$      auto_source           = t.auto_source,
      unlock_rule           = t.unlock_rule,
      unlocks_on            = public.onboarding_unlock_date(t.unlock_rule, p.start_date),
      required_topic_set_id = t.required_topic_set_id,$b$);

  v_new := replace(v_new,
$a$       s.track_order, s.auto_source, s.required_topic_set_id, s.required_mode_key)
      IS DISTINCT FROM
      (t.title, t.description, t.phase, t.category, t.source_manual_id, t.source_anchor,
       t.sort_order, t.is_required, t.owner_kind, t.assigned_to, t.track, t.blocked_by,
       t.track_order, t.auto_source, t.required_topic_set_id, t.required_mode_key)$a$,
$b$       s.track_order, s.auto_source, s.required_topic_set_id, s.required_mode_key,
       s.unlock_rule, s.unlocks_on)
      IS DISTINCT FROM
      (t.title, t.description, t.phase, t.category, t.source_manual_id, t.source_anchor,
       t.sort_order, t.is_required, t.owner_kind, t.assigned_to, t.track, t.blocked_by,
       t.track_order, t.auto_source, t.required_topic_set_id, t.required_mode_key,
       t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date))$b$);

  v_new := replace(v_new,
$a$    SELECT s.id, s.title, s.description, s.assigned_to, s.phase, s.task_id, ph.name AS phase_name$a$,
$b$    SELECT s.id, s.title, s.description, s.assigned_to, s.phase, s.task_id, s.unlocks_on, ph.name AS phase_name$b$);

  -- both due-date expressions: a dated step is due the day it opens
  v_new := replace(v_new,
$a$COALESCE(public.onboarding_phase_opens_on(p.agency_id, r.phase, p.start_date),$a$,
$b$COALESCE(r.unlocks_on,
                          public.onboarding_phase_opens_on(p.agency_id, r.phase, p.start_date),$b$);

  IF v_new = v_def
     OR position('s.unlock_rule, s.unlocks_on)' IN v_new) = 0
     OR position('t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date)' IN v_new) = 0
     OR position('unlocks_on            = public.onboarding_unlock_date' IN v_new) = 0
     OR position('s.task_id, s.unlocks_on, ph.name' IN v_new) = 0
     OR position('OR s.unlocks_on IS DISTINCT FROM' IN v_new) = 0
     OR (length(v_new) - length(replace(v_new, 'COALESCE(r.unlocks_on,', ''))) / length('COALESCE(r.unlocks_on,') <> 2
  THEN
    RAISE EXCEPTION 'onboarding_sync_plan patch did not apply cleanly';
  END IF;

  EXECUTE v_new;
END
$mig$;

-- Open-step notices: a dated step is not open before its date.
DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_open_step_notices(uuid,uuid)'::regprocedure);
  v_new := replace(v_def,
$a$        AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)$a$,
$b$        AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)
        AND (s.unlocks_on IS NULL
             OR s.unlocks_on <= (now() AT TIME ZONE 'America/Chicago')::date)$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'onboarding_open_step_notices patch did not apply';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- The Friday post still listed New Hire Documents in the Day 1 packet. They
-- came out of the packet on 2026-09-21.
DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_friday_notice(uuid,uuid)'::regprocedure);
  v_new := replace(v_def,
$a$      'Also: print the Day 1 packet — Login Packet plus the New Hire Documents ' ||
      '(W-4, I-9, State Farm Annual Certification, Non-Compete, Payroll and Bio).';$a$,
$b$      'Also: print the Day 1 packet (the Login Packet).';$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'onboarding_friday_notice patch did not apply';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- A changed start date moves every dated step with it.
CREATE OR REPLACE FUNCTION public.onboarding_plan_start_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.onboarding_sync_plan(NEW.id);
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_onboarding_plan_start_changed ON public.team_onboarding_plans;
CREATE TRIGGER trg_onboarding_plan_start_changed
  AFTER UPDATE OF start_date ON public.team_onboarding_plans
  FOR EACH ROW
  WHEN (OLD.start_date IS DISTINCT FROM NEW.start_date)
  EXECUTE FUNCTION public.onboarding_plan_start_changed();
