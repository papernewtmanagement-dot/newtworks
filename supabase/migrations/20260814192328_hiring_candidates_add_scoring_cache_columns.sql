ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cached_assessment_composite numeric,
  ADD COLUMN IF NOT EXISTS cached_protocol_validity_v numeric,
  ADD COLUMN IF NOT EXISTS cached_protocol_validity_label text,
  ADD COLUMN IF NOT EXISTS cached_scoring_version bigint,
  ADD COLUMN IF NOT EXISTS cached_at timestamptz;

CREATE TABLE IF NOT EXISTS public.hiregauge_scoring_version (
  agency_id uuid PRIMARY KEY,
  version bigint NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.hiregauge_scoring_version ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_all_hiregauge_scoring_version" ON public.hiregauge_scoring_version
  FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_hiregauge_scoring_version" ON public.hiregauge_scoring_version
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

INSERT INTO public.hiregauge_scoring_version (agency_id, version, updated_at)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 1, now())
ON CONFLICT (agency_id) DO NOTHING;
