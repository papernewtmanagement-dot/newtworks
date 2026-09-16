-- Retire the alerts table, part 2c of 3.
-- Fix found by smoke test: tasks.task_category is a fixed list
-- (web_app, admin, marketing, team_development, handbook, processes, finances)
-- and my first version of ensure_watcher_task tried to invent new values,
-- which the check constraint rejects. The watcher's identity now lives in
-- created_by instead, and task_category takes a real value from the existing
-- taxonomy. Dedupe keys on created_by plus related_id.

DROP FUNCTION IF EXISTS public.ensure_watcher_task(uuid,text,uuid,text,text,text);
DROP FUNCTION IF EXISTS public.close_watcher_task(uuid,text,uuid);

CREATE FUNCTION public.ensure_watcher_task(
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
  v_owner uuid := '67f7287d-7110-405f-a7bd-4db433e6d17f';
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

CREATE FUNCTION public.close_watcher_task(
  p_agency_id  uuid,
  p_source     text,
  p_related_id uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_closed integer := 0;
  v_by     text := 'watcher:' || p_source;
BEGIN
  WITH done AS (
    UPDATE public.tasks t
    SET status = 'completed', completed_at = now(), updated_at = now()
    WHERE t.agency_id = p_agency_id
      AND t.created_by = v_by
      AND t.related_id IS NOT DISTINCT FROM p_related_id
      AND t.status = 'open'
    RETURNING 1
  )
  SELECT count(*) INTO v_closed FROM done;
  RETURN v_closed;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.ensure_watcher_task(uuid,text,uuid,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.close_watcher_task(uuid,text,uuid) TO service_role;
