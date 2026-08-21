CREATE TABLE IF NOT EXISTS public.job_descriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,

  title text NOT NULL,
  role text NOT NULL,
  role_level text,
  category text NOT NULL DEFAULT 'agency',

  summary text,
  content text NOT NULL,

  version integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  effective_date date,

  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT job_descriptions_role_check
    CHECK (role IN ('Acquisition','Inside Sales','Reception','Support','Owner')),
  CONSTRAINT job_descriptions_role_level_check
    CHECK (role_level IS NULL OR role_level IN ('Account Manager','Account Associate','Support','Owner')),
  CONSTRAINT job_descriptions_category_check
    CHECK (category IN ('agency','admin'))
);

CREATE UNIQUE INDEX IF NOT EXISTS job_descriptions_one_active_role_level
  ON public.job_descriptions (agency_id, role, role_level)
  WHERE is_active = true AND role_level IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS job_descriptions_one_active_role_only
  ON public.job_descriptions (agency_id, role)
  WHERE is_active = true AND role_level IS NULL;

CREATE INDEX IF NOT EXISTS job_descriptions_agency_active_idx
  ON public.job_descriptions (agency_id, is_active, effective_date DESC);

ALTER TABLE public.job_descriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS job_descriptions_all_anon ON public.job_descriptions;
CREATE POLICY job_descriptions_all_anon
  ON public.job_descriptions FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS job_descriptions_all_authenticated ON public.job_descriptions;
CREATE POLICY job_descriptions_all_authenticated
  ON public.job_descriptions FOR ALL TO authenticated USING (true) WITH CHECK (true);
