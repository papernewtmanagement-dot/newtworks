CREATE TABLE IF NOT EXISTS public.hiregauge_facet_norms (
  agency_id uuid not null,
  facet text not null,
  ref_mean_0_100 numeric not null check (ref_mean_0_100 between 0 and 100),
  ref_sd_0_100 numeric not null check (ref_sd_0_100 > 0),
  source_scale text not null,
  citation text not null,
  retrieved_from text,
  notes text,
  updated_at timestamptz default now(),
  updated_by text,
  unique (agency_id, facet)
);

ALTER TABLE public.hiregauge_facet_norms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated_select_hiregauge_facet_norms" ON public.hiregauge_facet_norms;
CREATE POLICY "authenticated_select_hiregauge_facet_norms"
  ON public.hiregauge_facet_norms FOR SELECT
  TO authenticated
  USING (true);
