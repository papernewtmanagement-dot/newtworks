-- Recurring interview scheduling blackouts — a standing weekly rule
-- ("every Monday", or "every Thursday at 3:30pm") rather than a one-off
-- date. Complements hiring_interview_blackouts (one-off dates).
-- Peter directive 2026-08-12.

CREATE TABLE IF NOT EXISTS public.hiring_interview_recurring_blackouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6), -- 0=Sun..6=Sat
  start_time time,   -- NULL + end_time NULL = whole day, every occurrence
  end_time time,
  note text,
  starts_on date NOT NULL DEFAULT CURRENT_DATE,
  ends_on date,       -- NULL = indefinite
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE INDEX IF NOT EXISTS idx_hiring_interview_recurring_blackouts_agency
  ON public.hiring_interview_recurring_blackouts(agency_id, weekday);

ALTER TABLE public.hiring_interview_recurring_blackouts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_all_hiring_interview_recurring_blackouts" ON public.hiring_interview_recurring_blackouts
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_hiring_interview_recurring_blackouts" ON public.hiring_interview_recurring_blackouts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
