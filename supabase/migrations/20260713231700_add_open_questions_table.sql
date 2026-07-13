-- Structured open_questions table replacing the persistent_memory single-row blob pattern

CREATE TABLE IF NOT EXISTS public.open_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  title text NOT NULL,
  question text NOT NULL,
  domain text,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','resolved','deferred','superseded')),
  priority text NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('urgent','normal','someday')),
  trigger_condition text,
  resolution_note text,
  related_session_note text,
  opened_at timestamptz NOT NULL DEFAULT NOW(),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_open_questions_agency_status
  ON public.open_questions (agency_id, status, priority);

CREATE INDEX IF NOT EXISTS idx_open_questions_agency_domain_open
  ON public.open_questions (agency_id, domain)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_open_questions_opened_at
  ON public.open_questions (opened_at DESC);

-- Enable RLS + agency-scoped read/write policies
ALTER TABLE public.open_questions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS open_questions_agency_all ON public.open_questions;
CREATE POLICY open_questions_agency_all
  ON public.open_questions
  FOR ALL
  TO authenticated
  USING (agency_id IN (SELECT agency_id FROM public.users WHERE id = auth.uid()))
  WITH CHECK (agency_id IN (SELECT agency_id FROM public.users WHERE id = auth.uid()));

DROP POLICY IF EXISTS open_questions_service_role_all ON public.open_questions;
CREATE POLICY open_questions_service_role_all
  ON public.open_questions
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- Keep updated_at fresh + auto-set resolved_at on status transition
CREATE OR REPLACE FUNCTION public.tg_open_questions_updated_at()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  IF NEW.status <> OLD.status AND NEW.status = 'resolved' AND NEW.resolved_at IS NULL THEN
    NEW.resolved_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS open_questions_updated_at ON public.open_questions;
CREATE TRIGGER open_questions_updated_at
  BEFORE UPDATE ON public.open_questions
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_open_questions_updated_at();

COMMENT ON TABLE public.open_questions IS
  'Structured queue of open questions for Claude session-close protocol. Replaces the persistent_memory single-row blob pattern. One question = one row. Startup query: SELECT * FROM open_questions WHERE agency_id = ? AND status = ''open'' ORDER BY priority, opened_at.';
