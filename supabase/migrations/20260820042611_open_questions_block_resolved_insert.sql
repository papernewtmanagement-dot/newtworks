-- open_questions: close the resolved-row leak.
--
-- trg_open_questions_resolve_deletes fires BEFORE UPDATE only, so a row INSERTed
-- with status already 'resolved' or 'superseded' was never deleted and lived
-- forever. Three such rows were found stranded on 2026-08-19 (created by sessions
-- re-inserting an item that a concurrent session had already deleted, then
-- marking it done in the same statement).
--
-- Fix: a BEFORE INSERT guard that drops the row on the floor rather than storing
-- it. Same net effect as insert-then-resolve, no stranded rows possible.

CREATE OR REPLACE FUNCTION public.tg_open_questions_no_resolved_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- An open question that is already answered has nothing to track. Swallow it
  -- so the table only ever holds live items, matching the UPDATE-side behaviour.
  IF NEW.status IN ('resolved','superseded') THEN
    RETURN NULL;  -- suppress the INSERT
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_open_questions_no_resolved_insert ON public.open_questions;

CREATE TRIGGER trg_open_questions_no_resolved_insert
  BEFORE INSERT ON public.open_questions
  FOR EACH ROW EXECUTE FUNCTION public.tg_open_questions_no_resolved_insert();

COMMENT ON FUNCTION public.tg_open_questions_no_resolved_insert() IS
  'Suppresses INSERTs of open_questions rows that arrive already resolved or superseded. Companion to tg_open_questions_resolve_deletes, which only covers UPDATE. Added 2026-08-19 after three stranded resolved rows were found.';
