-- Fix RLS policy: use auth_user_id (matches current 22-table hardening pattern), not id

DROP POLICY IF EXISTS open_questions_agency_all ON public.open_questions;

CREATE POLICY open_questions_agency_all
  ON public.open_questions
  FOR ALL
  TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()))
  WITH CHECK (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

-- service_role policy unchanged (bypasses RLS entirely; MCP + Claude use this)
