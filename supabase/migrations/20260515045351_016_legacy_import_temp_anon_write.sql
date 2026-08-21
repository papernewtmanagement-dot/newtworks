DROP POLICY IF EXISTS "books_historical_imports_temp_anon_write" ON storage.objects;
CREATE POLICY "books_historical_imports_temp_anon_write"
  ON storage.objects FOR INSERT
  TO anon
  WITH CHECK (bucket_id = 'books_historical-imports');
