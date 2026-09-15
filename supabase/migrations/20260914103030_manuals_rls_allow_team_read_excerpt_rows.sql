-- Shared excerpt rows (manual_type='excerpt') are fragments embedded inside
-- handbook/processes pages and checklist help. The team must be able to read
-- them or every [Embedded excerpt from: X] marker renders the
-- "Missing shared excerpt" banner. Admin-only pages (manual_type='admin')
-- stay admin-only.
ALTER POLICY anon_read_manuals ON public.manuals
  USING (
    manual_type = ANY (ARRAY['handbook'::text, 'processes'::text, 'excerpt'::text])
    OR public.is_agency_admin()
  );
