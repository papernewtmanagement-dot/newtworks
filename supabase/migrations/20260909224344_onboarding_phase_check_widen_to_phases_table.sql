-- Phases are data now (onboarding_phases), so the 0-5 range check has to go.
ALTER TABLE public.onboarding_step_templates DROP CONSTRAINT IF EXISTS onboarding_step_templates_phase_check;
ALTER TABLE public.onboarding_step_templates
  ADD CONSTRAINT onboarding_step_templates_phase_check CHECK (phase >= 0 AND phase <= 1000);

ALTER TABLE public.team_onboarding_steps DROP CONSTRAINT IF EXISTS team_onboarding_steps_phase_check;
ALTER TABLE public.team_onboarding_steps
  ADD CONSTRAINT team_onboarding_steps_phase_check CHECK (phase >= 0 AND phase <= 1000);

ALTER TABLE public.onboarding_step_templates DROP CONSTRAINT IF EXISTS onboarding_step_templates_owner_kind_check;
ALTER TABLE public.onboarding_step_templates
  ADD CONSTRAINT onboarding_step_templates_owner_kind_check
  CHECK (owner_kind = ANY (ARRAY['new_hire','agent','admin']));

ALTER TABLE public.team_onboarding_steps DROP CONSTRAINT IF EXISTS team_onboarding_steps_owner_kind_check;
ALTER TABLE public.team_onboarding_steps
  ADD CONSTRAINT team_onboarding_steps_owner_kind_check
  CHECK (owner_kind = ANY (ARRAY['new_hire','agent','admin']));
