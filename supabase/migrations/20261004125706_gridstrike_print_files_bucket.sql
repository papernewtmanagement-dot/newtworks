-- Gridstrike print files (Peter 2026-10-04). A private bucket that the Gridstrike page in the
-- family section reads. Only owner, admin and the family login can open the files; there are no
-- insert, update or delete rules, so only the service role can add or change files.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('gridstrike', 'gridstrike', false, 52428800, ARRAY['application/pdf', 'application/json', 'application/zip'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY gridstrike_family_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'gridstrike' AND ((SELECT public.auth_is_family()) OR (SELECT public.is_agency_admin())));

