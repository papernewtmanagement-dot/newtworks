-- Handbook storage with versioning + archive support
CREATE TABLE IF NOT EXISTS public.handbook (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  title text NOT NULL,
  content text NOT NULL,
  source_url text,
  version integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  fetched_at timestamptz NOT NULL DEFAULT NOW(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- One active version per title per agency
CREATE UNIQUE INDEX IF NOT EXISTS handbook_one_active_per_title
ON public.handbook (agency_id, title)
WHERE is_active = true;

CREATE INDEX IF NOT EXISTS handbook_agency_active_idx
ON public.handbook (agency_id, is_active, fetched_at DESC);

-- RLS following BCC pattern (anon SELECT-permissive for the webapp dashboard read path)
ALTER TABLE public.handbook ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_handbook" ON public.handbook;
CREATE POLICY "anon_all_handbook" ON public.handbook FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "authenticated_all_handbook" ON public.handbook;
CREATE POLICY "authenticated_all_handbook" ON public.handbook FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.set_handbook_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS handbook_updated_at ON public.handbook;
CREATE TRIGGER handbook_updated_at
BEFORE UPDATE ON public.handbook
FOR EACH ROW EXECUTE FUNCTION public.set_handbook_updated_at();
