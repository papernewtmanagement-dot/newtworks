-- 20260707181729_glossary_terms_table

CREATE TABLE IF NOT EXISTS public.glossary_terms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  tag text NOT NULL,
  term text NOT NULL,
  definition text NOT NULL,
  sort_order integer,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, tag)
);

CREATE INDEX IF NOT EXISTS idx_glossary_terms_active
  ON public.glossary_terms (agency_id, sort_order NULLS LAST, term)
  WHERE is_active = true;

ALTER TABLE public.glossary_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "glossary_terms_agency_read" ON public.glossary_terms;
CREATE POLICY "glossary_terms_agency_read"
  ON public.glossary_terms
  FOR SELECT
  TO authenticated
  USING (agency_id IN (SELECT agency_id FROM public.users WHERE id = auth.uid()));

DROP POLICY IF EXISTS "glossary_terms_admin_write" ON public.glossary_terms;
CREATE POLICY "glossary_terms_admin_write"
  ON public.glossary_terms
  FOR ALL
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.agency_id = glossary_terms.agency_id AND u.role IN ('owner','manager'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.agency_id = glossary_terms.agency_id AND u.role IN ('owner','manager'))
  );

COMMENT ON TABLE public.glossary_terms IS 'Shared glossary terms. Referenced from handbook/processes pages via {{glossary:tag}} inline placeholder. All active terms render on the Glossary handbook page via {{glossary_all}}.';
