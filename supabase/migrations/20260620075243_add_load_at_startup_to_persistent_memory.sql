ALTER TABLE public.persistent_memory
ADD COLUMN IF NOT EXISTS load_at_startup BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.persistent_memory.load_at_startup IS
'True = row is pulled by the §2 startup query (always-on context). False = row is on-demand only, queried by Claude when the task requires it. Default false (conservative).';
