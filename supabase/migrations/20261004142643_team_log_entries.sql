-- Peter 2026-10-04: fix the Team page's notes and trend-summary panels, blank
-- since the notes moved into team_profile on 2026-07-16.
--
-- One reader for the team notes log (team_profile.behavioral_log), the format
-- team_log_append() writes: "## <date> · <kind>[ · source: <source>]
-- [ · **RESOLVED** <date>]", then the text, entries split by a --- line,
-- newest first (entry_no 1 = newest). The Team page and the trend-summary job
-- (team-trajectory-summarize) both read the log through it. Runs as the
-- caller, so team_profile's own rules keep it to admins.
CREATE OR REPLACE FUNCTION public.team_log_entries(p_team_ids uuid[])
 RETURNS TABLE(team_member_id uuid, entry_no integer, entry_date date, kind text, source text, resolved boolean, body text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT tp.team_member_id,
         e.ord::integer,
         substring(e.chunk from E'^## (\\d{4}-\\d{2}-\\d{2}) · ')::date,
         btrim(substring(e.chunk from E'^## \\d{4}-\\d{2}-\\d{2} · ([^\n·]+)')),
         btrim(substring(split_part(e.chunk, E'\n', 1) from ' · source: ([^·]+)')),
         split_part(e.chunk, E'\n', 1) LIKE '%**RESOLVED**%',
         btrim(CASE WHEN position(E'\n' in e.chunk) > 0
                    THEN substring(e.chunk from position(E'\n' in e.chunk) + 1)
                    ELSE '' END, E' \t\r\n')
  FROM public.team_profile tp
  CROSS JOIN LATERAL regexp_split_to_table(btrim(tp.behavioral_log, E' \t\r\n'), E'\n\n---\n\n')
       WITH ORDINALITY AS e(chunk, ord)
  WHERE tp.team_member_id = ANY(p_team_ids)
    AND e.chunk ~ E'^## \\d{4}-\\d{2}-\\d{2} · '
  ORDER BY tp.team_member_id, e.ord;
$function$;

REVOKE ALL ON FUNCTION public.team_log_entries(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_log_entries(uuid[]) TO authenticated, service_role;

