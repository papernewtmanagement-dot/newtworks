-- Whoever a step is assigned to can see and tick it, even though the plan
-- belongs to somebody else.
DROP POLICY IF EXISTS tos_select_assignee ON public.team_onboarding_steps;
CREATE POLICY tos_select_assignee ON public.team_onboarding_steps
  FOR SELECT TO authenticated
  USING (assigned_to IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

DROP POLICY IF EXISTS tos_update_assignee ON public.team_onboarding_steps;
CREATE POLICY tos_update_assignee ON public.team_onboarding_steps
  FOR UPDATE TO authenticated
  USING (assigned_to IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()))
  WITH CHECK (assigned_to IN (SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()));
