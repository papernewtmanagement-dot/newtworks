ALTER TABLE public.manuals ADD COLUMN IF NOT EXISTS notes text;
COMMENT ON COLUMN public.manuals.notes IS 'Internal editorial notes on the page (history, deprecation reasons, TODOs). Not rendered to readers.';
