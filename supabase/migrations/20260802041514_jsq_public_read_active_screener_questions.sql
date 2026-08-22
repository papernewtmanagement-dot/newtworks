-- Allow anonymous (unauthenticated) read of active screener questions.
-- These are rendered publicly on the careers application form, so they are
-- not sensitive. Needed so the careers page can be rendered from Vercel
-- using the browser-safe key instead of a privileged one.
DROP POLICY IF EXISTS jsq_public_active ON public.job_screener_questions;
CREATE POLICY jsq_public_active
  ON public.job_screener_questions
  FOR SELECT
  TO anon
  USING (is_active = true);
