-- Vacation weeks for interview scheduling (Peter directive 2026-09-11).
-- A series (anchor Sunday, every 13 weeks) plus per-occurrence moves. Any
-- date in a vacation week (Sun–Sat) has no interview slots. The Interview
-- Slots calendar shows the week as removed and can move an occurrence.

CREATE TABLE IF NOT EXISTS public.hiring_interview_vacation_series (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  label text NOT NULL DEFAULT 'Vacation week',
  anchor_week_start date NOT NULL,          -- a Sunday
  interval_weeks int NOT NULL DEFAULT 13,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hiring_interview_vacation_moves (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  series_id uuid NOT NULL REFERENCES public.hiring_interview_vacation_series(id) ON DELETE CASCADE,
  original_week_start date NOT NULL,        -- the occurrence being moved (a Sunday)
  moved_to_week_start date NOT NULL,        -- where it went (a Sunday)
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (series_id, original_week_start)
);

ALTER TABLE public.hiring_interview_vacation_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hiring_interview_vacation_moves ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_all_hiring_interview_vacation_series ON public.hiring_interview_vacation_series;
DROP POLICY IF EXISTS authenticated_all_hiring_interview_vacation_series ON public.hiring_interview_vacation_series;
CREATE POLICY anon_all_hiring_interview_vacation_series ON public.hiring_interview_vacation_series FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY authenticated_all_hiring_interview_vacation_series ON public.hiring_interview_vacation_series FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS anon_all_hiring_interview_vacation_moves ON public.hiring_interview_vacation_moves;
DROP POLICY IF EXISTS authenticated_all_hiring_interview_vacation_moves ON public.hiring_interview_vacation_moves;
CREATE POLICY anon_all_hiring_interview_vacation_moves ON public.hiring_interview_vacation_moves FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY authenticated_all_hiring_interview_vacation_moves ON public.hiring_interview_vacation_moves FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Peter's vacation week: week of Sunday 2026-09-27, then every 13 weeks.
INSERT INTO public.hiring_interview_vacation_series (agency_id, label, anchor_week_start, interval_weeks)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Vacation week', DATE '2026-09-27', 13
WHERE NOT EXISTS (
  SELECT 1 FROM public.hiring_interview_vacation_series
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND label = 'Vacation week'
);
