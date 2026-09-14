-- Peter 2026-09-13: a parent marked complete while its children are still open is an
-- error, and it needs to be stopped at the door. The Books cleanup epic was closed with
-- seven live children underneath it, three of which were top-priority money work.
CREATE OR REPLACE FUNCTION public.tasks_block_close_with_open_children()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_open int;
  v_titles text;
BEGIN
  IF NEW.status IN ('closed','completed') AND OLD.status = 'open' THEN
    SELECT count(*), string_agg(left(c.title,60), '; ' ORDER BY c.title)
      INTO v_open, v_titles
      FROM public.tasks c
     WHERE c.parent_task_id = NEW.id AND c.status = 'open';

    IF v_open > 0 THEN
      RAISE EXCEPTION
        'Cannot close "%" while % of its items are still open. Close them first, or move them to a different parent. Still open: %',
        left(NEW.title,60), v_open, v_titles
        USING ERRCODE = 'check_violation',
              HINT = 'A parent finishing before its children is almost always a mis-click, not a finished job.';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_tasks_block_close_with_open_children ON public.tasks;
CREATE TRIGGER trg_tasks_block_close_with_open_children
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.tasks_block_close_with_open_children();