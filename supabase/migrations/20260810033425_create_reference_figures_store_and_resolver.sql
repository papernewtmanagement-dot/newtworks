CREATE TABLE IF NOT EXISTS public.reference_figures (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  agency_id uuid NOT NULL,
  figure_key text NOT NULL,
  label text NOT NULL,
  value_display text NOT NULL,
  unit text NOT NULL DEFAULT 'usd',
  tax_year smallint NOT NULL,
  source_authority text NOT NULL,
  source_url text,
  last_verified_at timestamptz NOT NULL DEFAULT now(),
  verified_by text NOT NULL DEFAULT 'claude',
  previous_value_display text,
  previous_tax_year smallint,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reference_figures_key_shape CHECK (figure_key ~ '^[a-z][a-z0-9_]{2,80}$'),
  CONSTRAINT reference_figures_unit_chk CHECK (unit IN ('usd','percent','count','text')),
  CONSTRAINT reference_figures_authority_chk CHECK (source_authority IN ('IRS','SSA','CMS','HHS','FHFA')),
  CONSTRAINT reference_figures_verified_by_chk CHECK (verified_by IN ('claude','groq','peter'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_reference_figures_agency_key
  ON public.reference_figures (agency_id, figure_key);
CREATE INDEX IF NOT EXISTS idx_reference_figures_stale
  ON public.reference_figures (agency_id, tax_year) WHERE is_active;

ALTER TABLE public.reference_figures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_read_reference_figures ON public.reference_figures;
CREATE POLICY team_read_reference_figures ON public.reference_figures
  FOR SELECT USING (agency_id IN (SELECT u.agency_id FROM users u WHERE u.auth_user_id = auth.uid()));

DROP POLICY IF EXISTS admin_write_reference_figures ON public.reference_figures;
CREATE POLICY admin_write_reference_figures ON public.reference_figures
  FOR ALL USING (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = reference_figures.agency_id AND u.is_active = true)
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = reference_figures.agency_id AND u.is_active = true)
  );

-- Resolver: substitutes {{figure: key}} markers with the current stored value.
CREATE OR REPLACE FUNCTION public.resolve_figures(p_agency_id uuid, p_text text)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_out text := p_text; r record; v_val text;
BEGIN
  IF p_text IS NULL OR position('{{figure:' in p_text) = 0 THEN RETURN p_text; END IF;
  FOR r IN SELECT DISTINCT m[1] AS k
           FROM regexp_matches(p_text, '\{\{figure:\s*([a-z0-9_]+)\s*\}\}', 'g') AS m
  LOOP
    SELECT value_display INTO v_val FROM public.reference_figures
      WHERE agency_id = p_agency_id AND figure_key = r.k AND is_active;
    v_out := regexp_replace(v_out, '\{\{figure:\s*' || r.k || '\s*\}\}',
                            COALESCE(v_val, '[[missing figure: ' || r.k || ']]'), 'g');
  END LOOP;
  RETURN v_out;
END $fn$;

-- Read this instead of knowledge_faqs anywhere an answer is displayed.
CREATE OR REPLACE VIEW public.v_knowledge_faqs_resolved
WITH (security_invoker = true) AS
SELECT f.*,
       public.resolve_figures(f.agency_id, f.question) AS question_resolved,
       public.resolve_figures(f.agency_id, f.answer)   AS answer_resolved,
       (position('{{figure:' in COALESCE(f.answer,'') || COALESCE(f.question,'')) > 0) AS has_figures
FROM public.knowledge_faqs f;

COMMENT ON TABLE public.reference_figures IS
  'Year-specific federal figures referenced from knowledge_faqs answers via {{figure: key}} markers. The annual refresh updates ONLY this table — FAQ prose is never rewritten.';
