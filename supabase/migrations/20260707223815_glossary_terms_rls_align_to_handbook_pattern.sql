-- 20260707223815_glossary_terms_rls_align_to_handbook_pattern

-- Drop the broken policies (wrong users table mapping)
DROP POLICY IF EXISTS "glossary_terms_agency_read" ON public.glossary_terms;
DROP POLICY IF EXISTS "glossary_terms_admin_write" ON public.glossary_terms;
DROP POLICY IF EXISTS "glossary_terms_select_own_agency" ON public.glossary_terms;

-- Match handbook's working pattern: anon + authenticated, qual=true
CREATE POLICY "anon_all_glossary_terms"
  ON public.glossary_terms
  FOR ALL
  TO anon
  USING (true)
  WITH CHECK (true);

CREATE POLICY "authenticated_all_glossary_terms"
  ON public.glossary_terms
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);
