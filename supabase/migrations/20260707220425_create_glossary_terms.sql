-- 20260707220425_create_glossary_terms

CREATE TABLE IF NOT EXISTS public.glossary_terms (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id  UUID NOT NULL REFERENCES public.agencies(id) ON DELETE CASCADE,
  term       TEXT NOT NULL,
  definition TEXT NOT NULL,
  sort_order INTEGER,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS glossary_terms_agency_active_idx
  ON public.glossary_terms (agency_id, is_active, sort_order NULLS LAST, term);

-- RLS: mirror the pattern used by handbook / team — agency-scoped read for members.
ALTER TABLE public.glossary_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS glossary_terms_select_own_agency ON public.glossary_terms;
CREATE POLICY glossary_terms_select_own_agency
  ON public.glossary_terms
  FOR SELECT
  USING (
    agency_id IN (
      SELECT tm.agency_id FROM public.team tm WHERE tm.user_id = auth.uid()
    )
  );

COMMENT ON TABLE public.glossary_terms IS 'Agency-authored glossary of internal jargon (e.g., SMVC, WIN THE WEEK). Feeds the Glossary handbook page (dynamic render) and — future — inline info popovers via {{term:X}} resolution.';
COMMENT ON COLUMN public.glossary_terms.term IS 'Canonical spelling of the term (display casing preserved). Uniqueness enforced by user discipline, not DB constraint, so variants can coexist if needed.';
COMMENT ON COLUMN public.glossary_terms.definition IS 'Plain-language definition. Markdown allowed (rendered by same pipeline as handbook body).';
COMMENT ON COLUMN public.glossary_terms.sort_order IS 'Ascending numeric ordering within the glossary. NULL sorts last, then falls back to term ASC.';
