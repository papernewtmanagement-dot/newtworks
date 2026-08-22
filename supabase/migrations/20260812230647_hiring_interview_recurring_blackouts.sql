CREATE TABLE IF NOT EXISTS public.hiring_interview_recurring_blackouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time time,
  end_time time,
  note text,
  starts_on date NOT NULL DEFAULT CURRENT_DATE,
  ends_on date,
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

