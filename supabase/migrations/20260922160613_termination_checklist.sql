-- Termination checklist for the Team → Termination tab.
-- One row per agency. The terminate-team-member edge function reads it and
-- emails the filled-in checklist to Peter. Moved out of the Admin manual's
-- Termination page 2026-09-22.
CREATE TABLE IF NOT EXISTS public.termination_checklist (
  agency_id  uuid PRIMARY KEY,
  content_md text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.termination_checklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS termination_checklist_admin ON public.termination_checklist;
CREATE POLICY termination_checklist_admin ON public.termination_checklist
  FOR ALL TO authenticated
  USING (public.is_agency_admin() AND agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()))
  WITH CHECK (public.is_agency_admin() AND agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

GRANT SELECT, INSERT, UPDATE ON public.termination_checklist TO authenticated;
