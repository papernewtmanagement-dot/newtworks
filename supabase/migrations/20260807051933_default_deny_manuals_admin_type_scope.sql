
ALTER POLICY anon_read_manuals ON public.manuals
  TO authenticated
  USING ( (true) AND ( manual_type IN ('handbook','processes') OR public.is_agency_admin() ) );

