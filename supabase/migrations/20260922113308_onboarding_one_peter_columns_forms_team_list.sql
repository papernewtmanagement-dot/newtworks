-- Onboarding 2026-09-22, second pass (Peter).
-- 1) One Peter: every step owned by "the agent" is now assigned to Peter's
--    team record, so it lands on his task list like any other owner's step.
-- 2) Before start gets a third column (Day 1 prep). Tech setup gets four
--    columns: Paperwork and login, Desktop, Outlook, Jabber.
-- 3) Paperwork card shows the site forms (widget = 'team_forms').
-- 4) Jabber's team group fills itself from the team table: a sub-item group
--    with fill = 'team_list' gets one checkable line per active teammate,
--    minus the new hire. onboarding_fill_substeps() is the one place that
--    happens; onboarding_sync_plan() calls it, and a team change re-syncs
--    every open plan through the same trigger function templates use.
-- 5) Sub-item icons, matched by label like the pop-up instructions.

ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS widget text;
ALTER TABLE public.team_onboarding_steps     ADD COLUMN IF NOT EXISTS widget text;
ALTER TABLE public.onboarding_step_templates DROP CONSTRAINT IF EXISTS onboarding_step_templates_widget_chk;
ALTER TABLE public.onboarding_step_templates ADD CONSTRAINT onboarding_step_templates_widget_chk
  CHECK (widget IS NULL OR widget IN ('team_forms'));
ALTER TABLE public.team_onboarding_steps DROP CONSTRAINT IF EXISTS team_onboarding_steps_widget_chk;
ALTER TABLE public.team_onboarding_steps ADD CONSTRAINT team_onboarding_steps_widget_chk
  CHECK (widget IS NULL OR widget IN ('team_forms'));

CREATE TABLE IF NOT EXISTS public.onboarding_substep_icons (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     uuid NOT NULL,
  substep_label text NOT NULL,
  icon_url      text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, substep_label)
);
ALTER TABLE public.onboarding_substep_icons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osi_read ON public.onboarding_substep_icons;
CREATE POLICY osi_read ON public.onboarding_substep_icons
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS osi_admin_write ON public.onboarding_substep_icons;
CREATE POLICY osi_admin_write ON public.onboarding_substep_icons
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')));

CREATE OR REPLACE FUNCTION public.onboarding_fill_substeps(p_substeps jsonb, p_plan_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_substeps) <> 'array' OR p_substeps IS NULL THEN p_substeps
    WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_substeps) e
                     WHERE jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list') THEN p_substeps
    ELSE (
      SELECT jsonb_agg(
               CASE WHEN jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list'
                    THEN jsonb_set(e, '{items}', COALESCE((
                           SELECT jsonb_agg(n ORDER BY n)
                           FROM (
                             SELECT DISTINCT TRIM(COALESCE(NULLIF(TRIM(tm.nickname), ''), tm.first_name)
                                                  || ' ' || COALESCE(tm.last_name, '')) AS n
                             FROM public.team tm
                             JOIN public.team_onboarding_plans p ON p.id = p_plan_id
                             WHERE tm.agency_id = p.agency_id
                               AND tm.is_active IS TRUE
                               AND tm.archived_at IS NULL
                               AND COALESCE(tm.is_test_user, false) = false
                               AND tm.id IS DISTINCT FROM p.team_member_id
                           ) names
                           WHERE n <> ''), '[]'::jsonb))
                    ELSE e END
               ORDER BY ord)
      FROM jsonb_array_elements(p_substeps) WITH ORDINALITY AS x(e, ord)
    )
  END;
$$;

DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_new := v_def;

  v_new := replace(v_new,
$a$track_order, auto_source,
    unlock_rule, unlocks_on
  )$a$,
$b$track_order, auto_source,
    unlock_rule, unlocks_on, widget
  )$b$);
  v_new := replace(v_new,
$a$    t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date)
  FROM public.onboarding_templates_for_plan(p_plan_id) t$a$,
$b$    t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date), t.widget
  FROM public.onboarding_templates_for_plan(p_plan_id) t$b$);
  v_new := replace(v_new,
$a$      unlock_rule           = t.unlock_rule,$a$,
$b$      unlock_rule           = t.unlock_rule,
      widget                = t.widget,$b$);
  v_new := replace(v_new,
$a$       s.unlock_rule, s.unlocks_on)$a$,
$b$       s.unlock_rule, s.unlocks_on, s.widget)$b$);
  v_new := replace(v_new,
$a$       t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date))$a$,
$b$       t.unlock_rule, public.onboarding_unlock_date(t.unlock_rule, p.start_date), t.widget)$b$);
  -- every read of the template's sub-items goes through the fill
  v_new := replace(v_new, 't.substeps', 'public.onboarding_fill_substeps(t.substeps, p_plan_id)');

  IF position('unlock_rule, unlocks_on, widget' IN v_new) = 0
     OR position('p.start_date), t.widget' IN v_new) = 0
     OR position('widget                = t.widget' IN v_new) = 0
     OR position('s.unlocks_on, s.widget)' IN v_new) = 0
     OR position('p.start_date), t.widget)' IN v_new) = 0
     OR (length(v_new) - length(replace(v_new, 'onboarding_fill_substeps(t.substeps', '')))
          / length('onboarding_fill_substeps(t.substeps') < 5
  THEN
    RAISE EXCEPTION 'onboarding_sync_plan patch did not apply cleanly';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- A teammate joining, leaving or being renamed changes every Jabber team list.
DROP TRIGGER IF EXISTS trg_team_onboarding_team_list ON public.team;
CREATE TRIGGER trg_team_onboarding_team_list
  AFTER INSERT OR DELETE OR UPDATE OF first_name, last_name, nickname, is_active, archived_at, is_test_user
  ON public.team
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.onboarding_templates_changed();

-- ─── template data ─────────────────────────────────────────────────────
SELECT set_config('app.onboarding_template_sync', 'off', true);

-- 1) One Peter.
UPDATE public.onboarding_step_templates
   SET owner_kind = 'admin', assigned_to = public.onboarding_agent_team_id(agency_id)
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND owner_kind = 'agent';

-- 2) Before start: three columns.
UPDATE public.onboarding_step_templates
   SET track = 'Hiring and access'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND track = 'Hiring, access and Day 1 prep'
   AND template_key NOT IN ('t_friday_call','t_print_packet','agent_tech_setup');

UPDATE public.onboarding_step_templates
   SET track = 'Day 1 prep', track_order = 3,
       sort_order = CASE template_key WHEN 't_friday_call' THEN 10 WHEN 't_print_packet' THEN 20 ELSE 30 END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND template_key IN ('t_friday_call','t_print_packet','agent_tech_setup');

-- Tech setup: four columns.
UPDATE public.onboarding_step_templates
   SET title = 'Paperwork', widget = 'team_forms',
       track = 'Paperwork and login', track_order = 1, sort_order = 10
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_paperwork_pack';

UPDATE public.onboarding_step_templates
   SET track = 'Paperwork and login', track_order = 1, sort_order = 20,
       substeps = jsonb_set(substeps, '{0,items}',
                    (substeps -> 0 -> 'items') || '["Windows Hello for Business set up"]'::jsonb)
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_login'
   AND NOT ((substeps -> 0 -> 'items') ? 'Windows Hello for Business set up');

UPDATE public.onboarding_step_templates
   SET title = 'Network', track = 'Paperwork and login', track_order = 1, sort_order = 30
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_vpn';

DELETE FROM public.onboarding_step_templates
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_windows_hello';

UPDATE public.onboarding_step_templates
   SET track = 'Desktop', track_order = 2,
       sort_order = CASE template_key WHEN 't_taskbar' THEN 10 WHEN 't_teams_channels' THEN 20
                                      WHEN 't_bookmarks' THEN 30 ELSE 40 END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND template_key IN ('t_taskbar','t_teams_channels','t_bookmarks','t_headset');

UPDATE public.onboarding_step_templates
   SET substeps = replace(substeps::text,
                          '"Setup ECRM Opportunity Lists: Link"',
                          '"Setup ECRM Opportunity Lists: [Lead Process](/processes/2677309441)"')::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_headset';

UPDATE public.onboarding_step_templates
   SET track = 'Outlook', track_order = 3, sort_order = 10
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'outlook';

UPDATE public.onboarding_step_templates
   SET track = 'Jabber', track_order = 4, sort_order = 10,
       substeps = (
         SELECT jsonb_agg(
                  CASE WHEN e ->> 'group' = 'Search for each of the team'
                       THEN jsonb_build_object('group', e ->> 'group', 'fill', 'team_list', 'items', '[]'::jsonb)
                       ELSE e END
                  ORDER BY ord)
         FROM jsonb_array_elements(substeps) WITH ORDINALITY AS x(e, ord))
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_jabber';

-- The pop-up hung off a Jabber line Peter removed.
DELETE FROM public.onboarding_instructions
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND substep_label = 'Speed dials added from the speed-dial reference';

INSERT INTO public.onboarding_substep_icons (agency_id, substep_label, icon_url)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'Verify ZScaler running in task tray', '/onboarding-icons/zscaler.svg')
ON CONFLICT (agency_id, substep_label) DO UPDATE SET icon_url = EXCLUDED.icon_url;

-- One sync at the end, not one per statement.
SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
