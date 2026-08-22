
-- hiregauge_verdict_thresholds was previously marked "already deny-all,
-- skip" - that was wrong, it had a plain true-read policy for authenticated.
-- Locking it now per explicit go-ahead.
ALTER POLICY authenticated_read_hiregauge_verdict_thresholds ON public.hiregauge_verdict_thresholds
  TO authenticated USING ( public.is_agency_admin() );

