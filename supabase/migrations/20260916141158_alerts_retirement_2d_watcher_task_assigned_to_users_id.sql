-- Retire the alerts table, part 2d of 3.
-- Second fix found by smoke test: tasks.assigned_to points at users(id), not
-- team(id). The watcher tasks were being assigned Peter's team row id, which
-- the foreign key rejects. Uses his users row id now.

CREATE OR REPLACE FUNCTION public.ensure_watcher_task(
  p_agency_id   uuid,
  p_source      text,
  p_related_id  uuid,
  p_title       text,
  p_description text,
  p_priority    text DEFAULT 'medium',
  p_category    text DEFAULT 'team_development'
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_owner uuid := '6f0fa5c3-1bb9-4e96-8e6f-33705c89aa95';  -- Peter, users.id
  v_by    text := 'watcher:' || p_source;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.tasks t
    WHERE t.agency_id = p_agency_id
      AND t.created_by = v_by
      AND t.related_id IS NOT DISTINCT FROM p_related_id
      AND t.status = 'open'
  ) THEN
    RETURN false;
  END IF;

  INSERT INTO public.tasks
    (agency_id, title, description, assigned_to, created_by, priority, status,
     related_id, task_category, task_type, backlog_state)
  VALUES
    (p_agency_id, p_title, p_description, v_owner, v_by, p_priority, 'open',
     p_related_id, p_category, 'task', 'active');

  RETURN true;
END;
$fn$;
