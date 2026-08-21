-- Replace the blanket anon SELECT policy on settings (USING true) with one
-- that excludes secret-bearing rows. Front-end keeps reading config rows
-- (briefing_time, dashboard_period, drive folder ids, etc.); anon can no
-- longer read api keys, tokens, the service-role key, or the cron secret.
-- Edge Functions use the service-role key and bypass RLS, so automations
-- are unaffected. Reversible: DROP this policy and recreate USING (true).
DROP POLICY IF EXISTS anon_read_settings ON public.settings;

CREATE POLICY anon_read_settings_nonsecret ON public.settings
  FOR SELECT TO anon
  USING (setting_key !~* '(_key|_secret|_token|service_role|personal_access|cron_secret)');
