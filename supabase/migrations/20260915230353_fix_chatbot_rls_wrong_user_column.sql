-- chatbot_conversations / chatbot_messages read policies compared users.id to auth.uid().
-- users stores the Supabase auth subject in auth_user_id, not id, so both policies have been
-- false for every real user since they were written. Both tables were unreadable through RLS,
-- including by the owner. Repointed at auth_user_id; admin gate left exactly as it was.

DROP POLICY IF EXISTS chatbot_conversations_agency_select ON public.chatbot_conversations;
CREATE POLICY chatbot_conversations_agency_select
  ON public.chatbot_conversations
  FOR SELECT
  TO authenticated
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND is_agency_admin()
  );

DROP POLICY IF EXISTS chatbot_messages_agency_select ON public.chatbot_messages;
CREATE POLICY chatbot_messages_agency_select
  ON public.chatbot_messages
  FOR SELECT
  TO authenticated
  USING (
    agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
    AND is_agency_admin()
  );
