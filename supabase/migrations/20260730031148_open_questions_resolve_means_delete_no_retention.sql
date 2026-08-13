-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 03:11:48 UTC (ledger name: open_questions_resolve_means_delete_no_retention) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730031148.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- ==========================================================================
-- Fix: resolved open_questions accumulate as noise. Peter's directive is that
-- resolve = DELETE, not UPDATE. No retention window, no audit-in-place. The
-- session_notes table is the audit trail; open_questions is a live working
-- queue only.
--
-- Actions:
-- 1. Delete all currently-resolved / superseded rows (82 rows)
-- 2. Drop the prune function + cron I set up earlier this session — obsolete
--    now that resolve is a direct DELETE
-- 3. Add a trigger to enforce: any UPDATE that sets status IN
--    ('resolved','superseded') gets converted to a DELETE
-- ==========================================================================

-- 1. Drop the cron job + prune function
SELECT cron.unschedule('prune_open_questions_weekly');
DROP FUNCTION IF EXISTS public.prune_open_questions();

-- 2. Enforcement trigger: UPDATE to resolved/superseded status = DELETE the row
CREATE OR REPLACE FUNCTION public.tg_open_questions_resolve_deletes()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- If the update is transitioning to resolved or superseded, delete instead.
  IF NEW.status IN ('resolved','superseded')
     AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    DELETE FROM public.open_questions WHERE id = OLD.id;
    RETURN NULL;  -- suppress the UPDATE; row is gone
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
  'Enforces the "resolve = delete" contract on open_questions. Any UPDATE that transitions status to resolved or superseded is intercepted and the row is deleted outright. Callers can continue to write UPDATE ... SET status=resolved without changing patterns; the trigger converts to DELETE transparently.';

-- 3. Delete all currently-resolved / superseded rows (bypass the trigger by direct DELETE)
DELETE FROM public.open_questions
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND status IN ('resolved','superseded');
