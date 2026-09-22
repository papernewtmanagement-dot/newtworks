-- Tasks made for each teammate on a team card are created_by 'onboarding_team_card'.
-- Closing one has to tick that teammate's name, so the trigger listens to them too.
DROP TRIGGER IF EXISTS trg_task_tick_syncs_onboarding_step ON public.tasks;
CREATE TRIGGER trg_task_tick_syncs_onboarding_step
  AFTER UPDATE OF status ON public.tasks
  FOR EACH ROW
  WHEN (new.created_by IN ('onboarding_plan', 'onboarding_team_card'))
  EXECUTE FUNCTION public.task_tick_syncs_onboarding_step();
