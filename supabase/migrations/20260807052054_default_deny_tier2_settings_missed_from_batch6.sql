
-- settings was confirmed for the LOCK list but got missed from batch 6
-- when it was added to the authoritative list (batching had already been
-- laid out around the original alphabetical groups). Caught by F1 final
-- sweep check. Only one policy exists on this table - a regex-filtered
-- read, no separate write policy for authenticated at all.
ALTER POLICY anon_read_settings_nonsecret ON public.settings
  TO authenticated
  USING ( (setting_key !~* '(_key|_secret|_token|service_role|personal_access|cron_secret)'::text) AND public.is_agency_admin() );

