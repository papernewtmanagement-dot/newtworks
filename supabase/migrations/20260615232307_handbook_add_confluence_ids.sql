ALTER TABLE public.handbook
  ADD COLUMN IF NOT EXISTS confluence_page_id text,
  ADD COLUMN IF NOT EXISTS parent_page_id text;

CREATE INDEX IF NOT EXISTS handbook_confluence_page_id_idx
  ON public.handbook (agency_id, confluence_page_id);
