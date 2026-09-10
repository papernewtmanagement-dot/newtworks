CREATE TABLE IF NOT EXISTS public.onboarding_phases (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id   uuid NOT NULL,
  phase       int  NOT NULL,
  name        text NOT NULL,
  blurb       text,
  stage       text NOT NULL DEFAULT 'ramp',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, phase)
);

ALTER TABLE public.onboarding_phases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS onboarding_phases_read ON public.onboarding_phases;
CREATE POLICY onboarding_phases_read ON public.onboarding_phases
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS onboarding_phases_admin_write ON public.onboarding_phases;
CREATE POLICY onboarding_phases_admin_write ON public.onboarding_phases
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')));

INSERT INTO public.onboarding_phases (agency_id, phase, name, blurb, stage) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 10, 'On offer',                    'Offer out. Licensing starts, prior appointments end.',            'offer'),
 ('126794dd-25ff-47d2-a436-724499733365', 15, 'References and background',   'Runs as soon as they reply to the offer email.',                   'offer'),
 ('126794dd-25ff-47d2-a436-724499733365', 20, 'Two weeks before start',      'System access, equipment, cards, nameplate.',                      'pre_start'),
 ('126794dd-25ff-47d2-a436-724499733365', 25, 'Once they have an alias',     'Softphone and logins.',                                            'pre_start'),
 ('126794dd-25ff-47d2-a436-724499733365', 30, 'Once they have an extension', 'Team list and call flow.',                                         'pre_start'),
 ('126794dd-25ff-47d2-a436-724499733365', 35, 'Workspace ready',             'Desk, hardware, keys. Confirmed working before Day 1.',            'pre_start'),
 ('126794dd-25ff-47d2-a436-724499733365', 40, 'Friday before start',         'Welcome call, schedule, printed packet.',                          'pre_start'),
 ('126794dd-25ff-47d2-a436-724499733365', 50, 'Day 1',                       'Tech setup, paperwork, keys, first walkthrough.',                  'ramp'),
 ('126794dd-25ff-47d2-a436-724499733365', 55, 'Weeks 1-2',                   'Orientation, courses, shadowing. No production target.',           'ramp'),
 ('126794dd-25ff-47d2-a436-724499733365', 60, 'Weeks 3-4',                   'First independent work, daily wrap-ups, weekly 1:1s.',             'ramp'),
 ('126794dd-25ff-47d2-a436-724499733365', 65, 'Weeks 5-8',                   'Review cadence begins, Life pipeline starts, half shadow.',        'ramp'),
 ('126794dd-25ff-47d2-a436-724499733365', 70, 'Weeks 9-13',                  'Full quote share, weekly claims rhythm, cross-training.',          'ramp'),
 ('126794dd-25ff-47d2-a436-724499733365', 75, 'Week 14+',                    'Fully independent. Champions Circle pace, monthly audit rhythm.',  'ramp')
ON CONFLICT (agency_id, phase) DO UPDATE
  SET name = EXCLUDED.name, blurb = EXCLUDED.blurb, stage = EXCLUDED.stage, updated_at = now();

ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS owner_kind  text NOT NULL DEFAULT 'new_hire',
  ADD COLUMN IF NOT EXISTS assigned_to uuid;

ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS owner_kind  text NOT NULL DEFAULT 'new_hire',
  ADD COLUMN IF NOT EXISTS assigned_to uuid,
  ADD COLUMN IF NOT EXISTS task_id     uuid;

ALTER TABLE public.team_onboarding_plans
  ADD COLUMN IF NOT EXISTS candidate_id uuid,
  ADD COLUMN IF NOT EXISTS attached_at  timestamptz;

ALTER TABLE public.team_onboarding_plans ALTER COLUMN team_member_id DROP NOT NULL;

ALTER TABLE public.team_onboarding_plans DROP CONSTRAINT IF EXISTS team_onboarding_plans_subject_present;
ALTER TABLE public.team_onboarding_plans
  ADD CONSTRAINT team_onboarding_plans_subject_present
  CHECK (team_member_id IS NOT NULL OR candidate_id IS NOT NULL);
