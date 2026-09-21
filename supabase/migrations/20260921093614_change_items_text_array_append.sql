-- change_items: appending a quoted string to a text[] with || reads the string
-- as an array literal and fails. Cast each one to text.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef('public.change_items(uuid,text,text,text[],jsonb,jsonb)'::regprocedure) INTO v_def;
  v_new := regexp_replace(v_def, 'used \|\| ''([a-z_]+)'';', 'used || ''\1''::text;', 'g');
  IF v_new ~ 'used \|\| ''[a-z_]+'';' OR (SELECT count(*) FROM regexp_matches(v_new, '''::text;', 'g')) <> 6 THEN
    RAISE EXCEPTION 'change_items is not the expected shape; not patching blind';
  END IF;
  EXECUTE v_new;
END $mig$;
