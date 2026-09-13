-- Peter ruling 2026-09-11: opening a project loads the brief + operational rules only.
-- Other memory tagged to the project (session notes, specs, etc.) is never loaded on open;
-- it is searched first, before global memory, via pull_project_memory().

CREATE OR REPLACE FUNCTION public.pull_project(p_name text DEFAULT NULL)
RETURNS TABLE(rule_title text, rule_category text, rule_content text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_slug text;
  v_other text;
BEGIN
  IF p_name IS NULL THEN
    RETURN QUERY
      SELECT m.project::text,
             'project_index'::text,
             (m.title || ' | ' ||
              (SELECT count(*) FROM public.persistent_memory x
                WHERE x.agency_id = v_agency AND x.is_active AND x.project = m.project
                  AND x.category = 'operational_rule')::text
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

  -- brief + auto-load operational rules, stamped
  RETURN QUERY
    WITH u AS (
      UPDATE public.persistent_memory m
         SET last_read_at = NOW(), read_count = m.read_count + 1
       WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
         AND (m.category = 'project' OR (m.category = 'operational_rule' AND m.load_on_project_open))
      RETURNING m.title, m.category, m.content
    )
    SELECT u.title::text, u.category::text, u.content::text
      FROM u
     ORDER BY (u.category = 'project') DESC, u.title;

  -- what else is tagged here but not loaded
  SELECT string_agg(c.category || ' ' || c.n, ', ' ORDER BY c.category) INTO v_other
    FROM (SELECT m.category, count(*) AS n
            FROM public.persistent_memory m
           WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
             AND m.category NOT IN ('project','operational_rule')
           GROUP BY m.category) c;

  -- on-demand operational rules, titles only
  RETURN QUERY
    SELECT ('ON DEMAND in project ' || v_slug || ' — ' || count(*)
            || ' operational rules, titles only [chars]. Pull one with pull_project_memory(''' || v_slug || ''', ''title fragment''). Other memory tagged here, not loaded, searched first by pull_project_memory: '
            || coalesce(v_other, 'none'))::text,
           'project_index'::text,
           coalesce(string_agg(m.title || ' [' || length(m.content) || ']', E'\n' ORDER BY m.title), '(none)')::text
      FROM public.persistent_memory m
     WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
       AND m.category = 'operational_rule' AND NOT m.load_on_project_open;
END;
$function$;

COMMENT ON FUNCTION public.pull_project(text) IS 'Open a project: brief + auto-load operational rules (stamped) + titles-only index of the remaining operational rules. Nothing else tagged to the project is loaded. No arg lists projects.';

-- Project-first memory search. Searches rows tagged to the project; only if none match, falls back to everything else.
CREATE OR REPLACE FUNCTION public.pull_project_memory(p_project text, p_pattern text, p_category text DEFAULT NULL)
RETURNS TABLE(scope text, rule_title text, rule_category text, rule_content text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_slug text;
  v_hits int := 0;
BEGIN
  SELECT m.project INTO v_slug
    FROM public.persistent_memory m
   WHERE m.agency_id = v_agency AND m.is_active AND m.category = 'project'
     AND (m.project ILIKE p_project OR m.title ILIKE '%' || p_project || '%')
   ORDER BY (m.project ILIKE p_project) DESC, m.project
   LIMIT 1;
  v_slug := coalesce(v_slug, p_project);

  RETURN QUERY
    WITH u AS (
      UPDATE public.persistent_memory m
         SET last_read_at = NOW(), read_count = m.read_count + 1
       WHERE m.agency_id = v_agency AND m.is_active AND m.project = v_slug
         AND m.title ILIKE '%' || p_pattern || '%'
         AND (p_category IS NULL OR m.category = p_category)
      RETURNING m.title, m.category, m.content
    )
    SELECT 'project'::text, u.title::text, u.category::text, u.content::text
      FROM u ORDER BY u.category, u.title;
  GET DIAGNOSTICS v_hits = ROW_COUNT;

  IF v_hits = 0 THEN
    RETURN QUERY
      WITH u AS (
        UPDATE public.persistent_memory m
           SET last_read_at = NOW(), read_count = m.read_count + 1
         WHERE m.agency_id = v_agency AND m.is_active
           AND m.project IS DISTINCT FROM v_slug
           AND m.title ILIKE '%' || p_pattern || '%'
           AND (p_category IS NULL OR m.category = p_category)
        RETURNING m.title, m.category, m.content
      )
      SELECT 'global'::text, u.title::text, u.category::text, u.content::text
        FROM u ORDER BY u.category, u.title;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.pull_project_memory(text, text, text) IS 'Memory pull while inside a project: rows tagged to the project first (any category); global fallback only when the project has no match. Stamps reads like pull_memory.';
