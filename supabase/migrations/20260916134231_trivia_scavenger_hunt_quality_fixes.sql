-- Two fixes to the hunt generator found on first run:
-- 1. Snippets started and ended mid-word.
-- 2. The admin manual holds 30 dated homeschool-course lesson pages. They are
--    not agency process pages, so they made both bad stops and bad decoys.

CREATE OR REPLACE FUNCTION public._quiz_hunt_snippet(p_content text, p_title text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO 'public' AS $fn$
DECLARE v text; v_start int; v_cut int; v_snip text;
BEGIN
  v := COALESCE(p_content, '');
  v := regexp_replace(v, '<[^>]+>', ' ', 'g');
  v := regexp_replace(v, 'https?://\S+', ' ', 'g');
  v := regexp_replace(v, '[#*_>`|~-]+', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  IF COALESCE(p_title, '') <> '' THEN
    v := regexp_replace(v, '(?i)' || regexp_replace(p_title, '([\^$.|?*+()\[\]{}\\])', '\\\1', 'g'), '...', 'g');
  END IF;
  v := trim(v);

  v_start := greatest(1, (length(v) / 5)::int);
  -- step forward to the start of the next whole word
  v_cut := position(' ' in substr(v, v_start, 60));
  IF v_cut > 0 THEN v_start := v_start + v_cut; END IF;

  v_snip := substr(v, v_start, 320);
  -- drop the trailing part-word
  IF length(v_snip) = 320 THEN
    v_cut := length(v_snip) - position(' ' in reverse(v_snip));
    IF v_cut > 120 THEN v_snip := substr(v_snip, 1, v_cut); END IF;
  END IF;

  RETURN trim(v_snip);
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hunt_snippet(text, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public._quiz_hunt_build_stops(p_agency uuid, p_count int)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE
  v_row record; v_stops jsonb := '[]'::jsonb; v_decoys text[]; v_opts text[];
  v_shuffled text[]; v_correct int; v_snip text;
BEGIN
  FOR v_row IN
    SELECT m.id, m.title, m.manual_type, m.confluence_page_id, m.content
      FROM public.manuals m
     WHERE m.agency_id = p_agency
       AND m.is_active
       AND m.manual_type IN ('handbook', 'processes', 'admin')
       AND COALESCE(m.title, '') <> ''
       AND m.title !~ '^\d{2}/\d{2}/\d{4}'
       AND length(COALESCE(m.content, '')) >= 500
     ORDER BY random()
     LIMIT p_count
  LOOP
    SELECT array_agg(t) INTO v_decoys FROM (
      SELECT m2.title AS t FROM public.manuals m2
       WHERE m2.agency_id = p_agency AND m2.is_active
         AND m2.manual_type = v_row.manual_type
         AND m2.id <> v_row.id
         AND COALESCE(m2.title, '') <> ''
         AND m2.title !~ '^\d{2}/\d{2}/\d{4}'
         AND lower(m2.title) <> lower(v_row.title)
       ORDER BY random() LIMIT 3
    ) d;

    IF v_decoys IS NULL OR array_length(v_decoys, 1) < 3 THEN
      SELECT array_agg(t) INTO v_decoys FROM (
        SELECT m3.title AS t FROM public.manuals m3
         WHERE m3.agency_id = p_agency AND m3.is_active
           AND m3.manual_type IN ('handbook', 'processes', 'admin')
           AND m3.id <> v_row.id
           AND COALESCE(m3.title, '') <> ''
           AND m3.title !~ '^\d{2}/\d{2}/\d{4}'
           AND lower(m3.title) <> lower(v_row.title)
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
  SELECT count(*) INTO v_n FROM public.manuals m
   WHERE m.agency_id = v_agency AND m.is_active
     AND m.manual_type IN ('handbook', 'processes', 'admin')
     AND COALESCE(m.title, '') <> ''
     AND m.title !~ '^\d{2}/\d{2}/\d{4}'
     AND length(COALESCE(m.content, '')) >= 500;
  RETURN COALESCE(v_n, 0);
END; $fn$;

REVOKE ALL ON FUNCTION public.quiz_hunt_available() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_hunt_available() TO authenticated, service_role;
