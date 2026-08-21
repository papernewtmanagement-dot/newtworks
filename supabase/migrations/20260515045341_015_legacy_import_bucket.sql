INSERT INTO storage.buckets (id, name, public)
VALUES ('books_historical-imports', 'books_historical-imports', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "books_historical_imports_public_read" ON storage.objects;
CREATE POLICY "books_historical_imports_public_read"
  ON storage.objects FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'books_historical-imports');

DROP POLICY IF EXISTS "books_historical_imports_service_write" ON storage.objects;
CREATE POLICY "books_historical_imports_service_write"
  ON storage.objects FOR ALL
  TO service_role
  USING (bucket_id = 'books_historical-imports')
  WITH CHECK (bucket_id = 'books_historical-imports');
