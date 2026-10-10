-- A character's picture (shown on its sheet) and its icon (its piece on the map), both files in the private
-- rpg-images bucket, like a creature card's picture. Dusty is the first.
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS image_path text;
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS icon_path text;

DO $mig$
DECLARE d text; a text; b text;
BEGIN
  SELECT pg_get_functiondef('public.rpg_sheet(uuid, numeric)'::regprocedure) INTO d;
  a := '''color'', v_c.color, ''notes'', v_c.notes,';
  b := '''color'', v_c.color, ''notes'', v_c.notes, ''image_path'', v_c.image_path, ''icon_path'', v_c.icon_path,';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor not found once'; END IF;
  EXECUTE replace(d, a, b);

  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'rpg_map_view_block';
  a := '''color'', coalesce(cr.color, ch.color), ';
  b := '''color'', coalesce(cr.color, ch.color), ''icon'', ch.icon_path, ';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rpg_map_view_block anchor not found once'; END IF;
  EXECUTE replace(d, a, b);
END
$mig$;
