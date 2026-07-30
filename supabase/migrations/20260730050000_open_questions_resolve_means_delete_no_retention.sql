-- ==========================================================================
-- Fix: resolved open_questions accumulate as noise. Peter's directive
-- (2026-07-30): resolve = DELETE, not UPDATE. No retention window, no
-- audit-in-place. The session_notes table is the audit trail;
-- open_questions is a live working queue only.
--
-- Supersedes 20260730040000_prune_open_questions_cron.sql which set up a
-- 30-day retention window — obsolete now that resolve is an immediate DELETE.
-- ==========================================================================

-- 1. Drop the (now obsolete) prune function + cron
SELECT cron.unschedule('prune_open_questions_weekly');
DROP FUNCTION IF EXISTS public.prune_open_questions();

-- 2. Enforcement trigger: UPDATE to resolved/superseded status = DELETE
CREATE OR REPLACE FUNCTION public.tg_open_questions_resolve_deletes()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status IN ('resolved','superseded')
     AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    DELETE FROM public.open_questions WHERE id = OLD.id;
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_open_questions_resolve_deletes ON public.open_questions;
CREATE TRIGGER trg_open_questions_resolve_deletes
  BEFORE UPDATE ON public.open_questions
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_open_questions_resolve_deletes();

COMMENT ON FUNCTION public.tg_open_questions_resolve_deletes() IS
  'Enforces "resolve = delete" contract on open_questions. Any UPDATE that transitions status to resolved or superseded is intercepted and the row is deleted outright.';

-- 3. Delete all currently-resolved / superseded rows
DELETE FROM public.open_questions
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND status IN ('resolved','superseded');
