-- Scratch table: original extracted text of real statements, used to test the
-- statement reader before deploy. Dropped once the tests are done.
CREATE TABLE IF NOT EXISTS public.statement_reader_fixtures (
  name text PRIMARY KEY,
  source_document_id uuid,
  account_code text,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.statement_reader_fixtures ENABLE ROW LEVEL SECURITY;
