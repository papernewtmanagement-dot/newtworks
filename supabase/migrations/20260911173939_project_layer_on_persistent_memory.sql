-- Project layer on persistent_memory.
-- project: which project a row belongs to (NULL = global). One brief row per project (category='project', title=slug).
-- load_on_project_open: pulled automatically by pull_project(); everything else in the project stays on-demand.
ALTER TABLE public.persistent_memory ADD COLUMN IF NOT EXISTS project text;
ALTER TABLE public.persistent_memory ADD COLUMN IF NOT EXISTS load_on_project_open boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS persistent_memory_project_idx ON public.persistent_memory (project) WHERE project IS NOT NULL;

COMMENT ON COLUMN public.persistent_memory.project IS 'Project slug this row belongs to. NULL = global. Brief row for a project has category=project and title=slug.';
COMMENT ON COLUMN public.persistent_memory.load_on_project_open IS 'true = pull_project(slug) returns this row automatically. Keep the auto-load set small; the rest of the project is on demand by title.';

-- pull_project(name): open a project in one call.
--   no arg  -> list projects (slug, title, row count)
--   name    -> brief row + every load_on_project_open row (stamped), then one titles-only index row of the on-demand rest
CREATE OR REPLACE FUNCTION public.pull_project(p_name text DEFAULT NULL)
RETURNS TABLE(rule_title text, rule_category text, rule_content text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_slug text;
BEGIN
  IF p_name IS NULL THEN
    RETURN QUERY
      SELECT m.project::text,
             'project_index'::text,
             (m.title || ' | ' ||
              (SELECT count(*) FROM public.persistent_memory x
                WHERE x.agency_id = v_agency AND x.is_active AND x.project = m.project
                  AND x.category NOT IN ('project','session_note','session_notes'))::text
              || ' rules')::text
        FROM public.persistent_memory m
       WHERE m.agency_id = v_agency AND m.is_active AND m.category = 'project'
       ORDER BY m.project;
    RETURN;
  END IF;

  SELECT m.project INTO v_slug
    FROM public.persistent_memory m
   WHERE m.agency_id = v_agency AND m.is_active AND m.category = 'project'
     AND (m.project ILIKE p_name OR m.title ILIKE '%' || p_name || '%')
   ORDER BY (m.project ILIKE p_name) DESC, m.project
   LIMIT 1;

  IF v_slug IS NULL THEN
    RETURN QUERY
      SELECT ('NO PROJECT MATCHES: ' || p_name)::text, 'project_index'::text,
             'Call pull_project() with no argument to list projects.'::text;
    RETURN;
  END IF;

  RETURN QUERY
    WITH u AS (
      UPDATE public.persistent_memory m
         SET last_read_at = NOW(), read_count = m.read_count + 1
       WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
         AND (m.category = 'project' OR m.load_on_project_open)
      RETURNING m.title, m.category, m.content
    )
    SELECT u.title::text, u.category::text, u.content::text
      FROM u
     ORDER BY (u.category = 'project') DESC, u.title;

  RETURN QUERY
    SELECT ('ON DEMAND in project ' || v_slug || ' — ' || count(*) || ' rows, titles only [chars]. Pull one with pull_memory(''title fragment''). Session notes tagged to this project: '
            || (SELECT count(*) FROM public.persistent_memory s
                 WHERE s.agency_id = v_agency AND s.is_active AND s.project = v_slug
                   AND s.category IN ('session_note','session_notes')))::text,
           'project_index'::text,
           coalesce(string_agg(m.title || ' [' || length(m.content) || ']', E'\n' ORDER BY m.title), '(none)')::text
      FROM public.persistent_memory m
     WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
       AND m.category NOT IN ('project','session_note','session_notes')
       AND NOT m.load_on_project_open;
END;
$function$;

COMMENT ON FUNCTION public.pull_project(text) IS 'Open a project: brief + auto-load rules (stamped) + titles-only index of the rest. No arg lists projects.';
