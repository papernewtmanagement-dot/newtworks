CREATE TABLE IF NOT EXISTS public.book_performance_goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  year integer NOT NULL,
  lob text NOT NULL CHECK (lob IN ('auto','fire','life')),
  metric text NOT NULL CHECK (metric IN ('new','lost','gain','pif','premium','new_pay')),
  target_value numeric(12,2) NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, year, lob, metric)
);

CREATE INDEX IF NOT EXISTS idx_book_performance_goals_agency_year
  ON public.book_performance_goals (agency_id, year);

ALTER TABLE public.book_performance_goals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "book_performance_goals_anon_select" ON public.book_performance_goals;
CREATE POLICY "book_performance_goals_anon_select" ON public.book_performance_goals FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "book_performance_goals_authenticated_all" ON public.book_performance_goals;
CREATE POLICY "book_performance_goals_authenticated_all" ON public.book_performance_goals FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT ON public.book_performance_goals TO anon;
GRANT ALL ON public.book_performance_goals TO authenticated;
