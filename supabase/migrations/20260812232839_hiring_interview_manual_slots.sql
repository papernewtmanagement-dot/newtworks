CREATE TABLE IF NOT EXISTS public.hiring_interview_manual_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  slot_date date NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE INDEX IF NOT EXISTS idx_hiring_interview_manual_slots_date
  ON public.hiring_interview_manual_slots(agency_id, slot_date);

ALTER TABLE public.hiring_interview_manual_slots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_all_hiring_interview_manual_slots" ON public.hiring_interview_manual_slots
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_hiring_interview_manual_slots" ON public.hiring_interview_manual_slots
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

