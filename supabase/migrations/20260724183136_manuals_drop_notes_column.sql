-- Drop manuals.notes: was used for Confluence-ingestion notes; no longer needed
-- since manuals are directly editable in Newtworks.
ALTER TABLE public.manuals DROP COLUMN IF EXISTS notes;
