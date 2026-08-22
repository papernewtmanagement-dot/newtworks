CREATE TABLE IF NOT EXISTS public.hiring_interview_blackouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  blackout_date date NOT NULL,
  start_time time,
  end_time time,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE INDEX IF NOT EXISTS idx_hiring_interview_blackouts_date
  ON public.hiring_interview_blackouts(agency_id, blackout_date);

ALTER TABLE public.hiring_interview_blackouts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_all_hiring_interview_blackouts" ON public.hiring_interview_blackouts
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_hiring_interview_blackouts" ON public.hiring_interview_blackouts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

