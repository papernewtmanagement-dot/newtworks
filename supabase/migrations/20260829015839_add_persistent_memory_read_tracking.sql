-- 1. Bookkeeping columns. NULL last_read_at = never pulled since tracking began.
ALTER TABLE public.persistent_memory
  ADD COLUMN IF NOT EXISTS last_read_at timestamptz;

ALTER TABLE public.persistent_memory
  ADD COLUMN IF NOT EXISTS read_count integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_persistent_memory_last_read
  ON public.persistent_memory (agency_id, category, last_read_at);

-- 2. Dedicated updated_at trigger for this table only.
--    set_updated_at() is shared by other tables and must not be altered.
--    Read-stamping must NOT bump updated_at, or session_note retention breaks
--    (prune_session_notes deletes on updated_at < NOW() - 30 days).
CREATE OR REPLACE FUNCTION public.persistent_memory_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Caller set updated_at explicitly -> respect it.
  IF NEW.updated_at IS DISTINCT FROM OLD.updated_at THEN
    RETURN NEW;
  END IF;

  -- Substantive content unchanged (read stamp only) -> freeze the content clock.
  IF NEW.content        IS NOT DISTINCT FROM OLD.content
 AND NEW.title          IS NOT DISTINCT FROM OLD.title
 AND NEW.category       IS NOT DISTINCT FROM OLD.category
 AND NEW.load_at_startup IS NOT DISTINCT FROM OLD.load_at_startup
 AND NEW.source         IS NOT DISTINCT FROM OLD.source
  THEN
    NEW.updated_at = OLD.updated_at;
  ELSE
    NEW.updated_at = NOW();
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_persistent_memory_updated ON public.persistent_memory;

CREATE TRIGGER trg_persistent_memory_updated
  BEFORE UPDATE ON public.persistent_memory
  FOR EACH ROW EXECUTE FUNCTION public.persistent_memory_set_updated_at();

-- 3. Read-and-stamp in one call. Reading IS the update, so nothing to remember.
CREATE OR REPLACE FUNCTION public.pull_memory(
  p_pattern  text,
  p_category text DEFAULT NULL
)
RETURNS TABLE(rule_title text, rule_category text, rule_content text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  UPDATE public.persistent_memory m
     SET last_read_at = NOW(),
         read_count   = m.read_count + 1
   WHERE m.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND m.title ILIKE '%' || p_pattern || '%'
     AND (p_category IS NULL OR m.category = p_category)
  RETURNING m.title::text, m.category::text, m.content::text;
END;
$function$;
