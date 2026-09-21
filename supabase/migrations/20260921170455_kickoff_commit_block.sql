-- The [Commits] ... [Commits end] block from the Daily Kickoff page, raw.
-- The Dashboard's Checklist tab shows the commit choices until today's commit
-- is saved (Peter 2026-09-21). It needs only this block, not the whole 185KB
-- page. No parsing here: the week filter and the line parsing stay in
-- src/lib/markdown.js (commitOptions), the same code the Kickoff page runs.
CREATE OR REPLACE FUNCTION public.kickoff_commit_block()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN s = 0 THEN NULL
           WHEN e > s THEN substr(m.content, s, e - s + length('[Commits end]'))
           ELSE substr(m.content, s)
         END
  FROM (
    SELECT content,
           position('[Commits]' in content) AS s,
           position('[Commits end]' in content) AS e
    FROM public.manuals
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND manual_type = 'processes'
      AND title = 'Daily Kickoff'
      AND is_active IS DISTINCT FROM false
      AND archived_at IS NULL
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 1
  ) m;
$function$;

REVOKE ALL ON FUNCTION public.kickoff_commit_block() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.kickoff_commit_block() TO authenticated, service_role;
