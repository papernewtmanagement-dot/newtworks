-- Batch 1 of 8: default-deny tier 2 sweep. R1 transform on true/open read
-- policies. Only SELECT (polcmd 'r') policies touched; existing INSERT/
-- UPDATE/DELETE policies on assessment_invitations and automation_recipes
-- left untouched per instruction (do not touch 'a'/'w'/'d' policies).
-- bot_prompts_admin_all (ALL) left as-is: already gated to owner/manager
-- on every command via its own subquery; the actual hole on that table was
-- the separate anon_read_bot_prompts true-policy, which this migration fixes.

ALTER POLICY anon_read_agency_huddle_config ON public.agency_huddle_config
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_assessment_invitations ON public.assessment_invitations
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_automation_recipes ON public.automation_recipes
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_automation_run_log ON public.automation_run_log
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_bank_account_map ON public.bank_account_map
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_bank_register_weekly_snapshot ON public.bank_register_weekly_snapshot
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_bot_prompts ON public.bot_prompts
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY anon_read_briefings ON public.briefings
  TO authenticated
  USING ( public.is_agency_admin() );

ALTER POLICY chatbot_conversations_agency_select ON public.chatbot_conversations
  TO authenticated
  USING (
    (agency_id IN ( SELECT users.agency_id FROM users WHERE (users.id = auth.uid()) ))
    AND public.is_agency_admin()
  );

ALTER POLICY chatbot_messages_agency_select ON public.chatbot_messages
  TO authenticated
  USING (
    (agency_id IN ( SELECT users.agency_id FROM users WHERE (users.id = auth.uid()) ))
    AND public.is_agency_admin()
  );
