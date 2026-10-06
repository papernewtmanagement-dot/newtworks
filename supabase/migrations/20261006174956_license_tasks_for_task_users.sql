-- Licenses and CE due: one rule for who has one coming up. Ongoing (Development) shows it
-- for everyone except Peter and Alvi, who get a task in the task list instead.
CREATE OR REPLACE FUNCTION public.licenses_due(p_team_member_id uuid)
 RETURNS SETOF public.team_licenses
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- From the first reminder email (90 days out) until done. The same rows the
  -- license-reminder-runner emails about: active, dated, CE only where CE is required.
  SELECT l.*
  FROM public.team_licenses l
  WHERE l.team_member_id = p_team_member_id
    AND l.status = 'active'
    AND l.due_date IS NOT NULL
    AND l.due_date <= CURRENT_DATE + 90
    AND NOT ((l.license_type LIKE '%\_ce'
              OR l.license_type IN ('series_6_annual_compliance', 'series_6_regulatory_element'))
             AND l.ce_required IS FALSE);
$function$;

REVOKE EXECUTE ON FUNCTION public.licenses_due(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.licenses_due(uuid) TO service_role;

DO $do$
DECLARE
  v_def text := pg_get_functiondef('public.development_ongoing(uuid)'::regprocedure);
  v_old text := '    FROM public.team_licenses l
    WHERE l.team_member_id = p_team_member_id
      AND l.status = ''active''
      AND l.due_date IS NOT NULL
      AND l.due_date <= CURRENT_DATE + 90
      AND NOT ((l.license_type LIKE ''%\_ce''
                OR l.license_type IN (''series_6_annual_compliance'', ''series_6_regulatory_element''))
               AND l.ce_required IS FALSE)
';
  v_new text := '    FROM public.licenses_due(p_team_member_id) l
    WHERE NOT v_tasks
';
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'development_ongoing: expected the license query exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$do$;

-- Peter's and Alvi's licenses and CE live in the task list. One open task per license
-- cycle (the license and its due date). It closes when the license is renewed (the due
-- date moves) or leaves the list, and goes when the license is deleted.
CREATE OR REPLACE FUNCTION public.license_tasks_sync(p_license_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n int := 0;
  v_k int;
BEGIN
  DELETE FROM public.tasks k
  WHERE k.created_by = 'license_due'
    AND (p_license_id IS NULL OR k.related_id = p_license_id)
    AND NOT EXISTS (SELECT 1 FROM public.team_licenses l WHERE l.id = k.related_id);

  UPDATE public.tasks k
  SET status = 'completed', completed_at = now(), updated_at = now()
  WHERE k.created_by = 'license_due' AND k.status <> 'completed'
    AND (p_license_id IS NULL OR k.related_id = p_license_id)
    AND NOT EXISTS (SELECT 1 FROM public.team_licenses l, LATERAL public.licenses_due(l.team_member_id) d
                    WHERE l.id = k.related_id AND d.id = l.id AND d.due_date = k.due_date);
  GET DIAGNOSTICS v_k = ROW_COUNT;
  v_n := v_n + v_k;

  INSERT INTO public.tasks (agency_id, title, description, assigned_to, task_category, task_type,
                            status, due_date, related_id, created_by)
  SELECT t.agency_id,
         'Renew ' || initcap(replace(l.license_type, '_', ' ')),
         trim(both E' \n' FROM COALESCE(l.authority, '')
              || CASE WHEN l.hours_required IS NOT NULL THEN E'\nHours required: ' || l.hours_required ELSE '' END
              || CASE WHEN l.notes IS NOT NULL AND l.notes <> '' THEN E'\n' || l.notes ELSE '' END),
         t.user_id, 'team_development', 'task', 'open', l.due_date, l.id, 'license_due'
  FROM public.team t
  CROSS JOIN LATERAL public.licenses_due(t.id) l
  WHERE t.is_active IS TRUE AND t.archived_at IS NULL
    AND t.user_id IS NOT NULL
    AND public.user_gets_tasks(t.user_id)
    AND (p_license_id IS NULL OR l.id = p_license_id)
    AND NOT EXISTS (SELECT 1 FROM public.tasks k
                    WHERE k.related_id = l.id AND k.created_by = 'license_due' AND k.due_date = l.due_date);
  GET DIAGNOSTICS v_k = ROW_COUNT;
  RETURN v_n + v_k;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.license_tasks_sync(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.license_tasks_sync(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.tg_license_tasks_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.license_tasks_sync(COALESCE(NEW.id, OLD.id));
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_license_tasks_sync ON public.team_licenses;
CREATE TRIGGER trg_license_tasks_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.team_licenses
  FOR EACH ROW EXECUTE FUNCTION public.tg_license_tasks_sync();

-- The 90-day window opens on its own as dates pass, so look every morning too.
SELECT cron.schedule('license-tasks-daily', '10 11 * * *', 'SELECT public.license_tasks_sync();');

SELECT public.license_tasks_sync();
