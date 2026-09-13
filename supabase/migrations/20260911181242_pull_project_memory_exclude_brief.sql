-- The project brief is already loaded on open; searching should never return it again.
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
         AND m.category <> 'project'
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
           AND m.category <> 'project'
           AND m.title ILIKE '%' || p_pattern || '%'
           AND (p_category IS NULL OR m.category = p_category)
        RETURNING m.title, m.category, m.content
      )
      SELECT 'global'::text, u.title::text, u.category::text, u.content::text
        FROM u ORDER BY u.category, u.title;
  END IF;
END;
$function$;
