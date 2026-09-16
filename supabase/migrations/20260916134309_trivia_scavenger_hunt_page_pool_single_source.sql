-- One definition of "a page the hunt may use", called by both the builder and
-- the availability count, so the two can never drift apart.
-- Excludes the whole Financial Literacy Course subtree (65 pages): that is
-- Peter's homeschool co-op curriculum, not agency process material, and it made
-- both unguessable stops and meaningless decoys.

CREATE OR REPLACE FUNCTION public._quiz_hunt_pages(p_agency uuid)
RETURNS TABLE (id uuid, title text, manual_type text, confluence_page_id text, content text)
LANGUAGE sql STABLE SET search_path TO 'public' AS $fn$
  WITH RECURSIVE course AS (
    SELECT m.id, m.confluence_page_id
      FROM public.manuals m
     WHERE m.agency_id = p_agency
       AND m.title ILIKE 'Financial Literacy Course%'
    UNION ALL
    SELECT c.id, c.confluence_page_id
      FROM public.manuals c
      JOIN course t ON c.parent_page_id = t.confluence_page_id
     WHERE c.agency_id = p_agency
  )
  SELECT m.id, m.title, m.manual_type, m.confluence_page_id, m.content
    FROM public.manuals m
   WHERE m.agency_id = p_agency
     AND m.is_active
     AND m.manual_type IN ('handbook', 'processes', 'admin')
     AND COALESCE(m.title, '') <> ''
     AND length(COALESCE(m.content, '')) >= 500
     AND NOT EXISTS (SELECT 1 FROM course c WHERE c.id = m.id);
$fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_pages(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public._quiz_hunt_build_stops(p_agency uuid, p_count int)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE
  v_row record; v_stops jsonb := '[]'::jsonb; v_decoys text[]; v_opts text[];
  v_shuffled text[]; v_correct int; v_snip text;
BEGIN
  FOR v_row IN
    SELECT p.id, p.title, p.manual_type, p.confluence_page_id, p.content
      FROM public._quiz_hunt_pages(p_agency) p
     ORDER BY random() LIMIT p_count
  LOOP
    SELECT array_agg(t) INTO v_decoys FROM (
      SELECT p2.title AS t FROM public._quiz_hunt_pages(p_agency) p2
       WHERE p2.manual_type = v_row.manual_type
         AND p2.id <> v_row.id
         AND lower(p2.title) <> lower(v_row.title)
       ORDER BY random() LIMIT 3
    ) d;

    IF v_decoys IS NULL OR array_length(v_decoys, 1) < 3 THEN
      SELECT array_agg(t) INTO v_decoys FROM (
        SELECT p3.title AS t FROM public._quiz_hunt_pages(p_agency) p3
         WHERE p3.id <> v_row.id
           AND lower(p3.title) <> lower(v_row.title)
         ORDER BY random() LIMIT 3
      ) d2;
    END IF;

    IF v_decoys IS NULL OR array_length(v_decoys, 1) < 3 THEN CONTINUE; END IF;

    v_snip := public._quiz_hunt_snippet(v_row.content, v_row.title);
    IF length(COALESCE(v_snip, '')) < 80 THEN CONTINUE; END IF;

    v_opts := ARRAY[v_row.title] || v_decoys;
    SELECT array_agg(o ORDER BY random()) INTO v_shuffled FROM unnest(v_opts) o;
    v_correct := array_position(v_shuffled, v_row.title) - 1;

    v_stops := v_stops || jsonb_build_array(jsonb_build_object(
      'manual_id', v_row.id,
      'manual_type', v_row.manual_type,
      'page_id', v_row.confluence_page_id,
      'snippet', v_snip,
      'options', to_jsonb(v_shuffled),
      'correct_index', v_correct,
      'answered', false,
      'chosen', NULL,
      'correct', NULL
    ));
  END LOOP;

  RETURN v_stops;
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_build_stops(uuid, int) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.quiz_hunt_available()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_agency uuid; v_n int;
BEGIN
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_agency IS NULL THEN RETURN 0; END IF;
  SELECT count(*) INTO v_n FROM public._quiz_hunt_pages(v_agency);
  RETURN COALESCE(v_n, 0);
END; $fn$;

REVOKE ALL ON FUNCTION public.quiz_hunt_available() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_available() TO authenticated, service_role;
