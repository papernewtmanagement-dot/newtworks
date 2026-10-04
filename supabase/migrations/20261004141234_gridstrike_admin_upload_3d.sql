-- Gridstrike page (2026-10-04): owner and admin can add or replace 3D print files in the 3d/ folder of the
-- private gridstrike bucket, straight from the page. The family login still only reads. No delete rule: removing a
-- file stays a Claude job. Adds model/stl to the bucket's allowed file types (zips and PDFs were already allowed).
UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['application/pdf', 'application/json', 'application/zip', 'model/stl']
 WHERE id = 'gridstrike';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
                 AND policyname = 'gridstrike_admin_add_3d') THEN
    CREATE POLICY gridstrike_admin_add_3d ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (bucket_id = 'gridstrike' AND name LIKE '3d/%' AND (SELECT public.is_agency_admin()));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
                 AND policyname = 'gridstrike_admin_replace_3d') THEN
    CREATE POLICY gridstrike_admin_replace_3d ON storage.objects
      FOR UPDATE TO authenticated
      USING (bucket_id = 'gridstrike' AND name LIKE '3d/%' AND (SELECT public.is_agency_admin()))
      WITH CHECK (bucket_id = 'gridstrike' AND name LIKE '3d/%' AND (SELECT public.is_agency_admin()));
  END IF;
END $$;

