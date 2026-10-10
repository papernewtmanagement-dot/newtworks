-- The app's database login refuses a DELETE with no WHERE (a guard against wiping a table by mistake). These two
-- emptied a whole table on purpose, so a parent saving any creature card in the app (a picture upload on the Cistern
-- Turtle card, Peter 2026-10-10) failed with "DELETE requires a WHERE clause". Same work, with WHERE true.
CREATE OR REPLACE FUNCTION public.rpg_map_cache_watch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Forgets what the saved map holds when what it was worked out from changes (step 13), and only that (speed step 4,
-- Peter 2026-10-09: stop wiping the whole saved map on every change):
--  * a setting (rpg_settings): only the map settings (map_...) feed the saved map; the rest (the walk, the clock, sight,
--    encounters) are read live and forget nothing. The map settings are compared with what they were when the map was
--    last saved (a fingerprint kept on the saved map, level -1): a road setting changed (map_road_...) forgets the
--    saved roads and the District grids houses and streets (notes: roads, houses, streets); any other map setting
--    changed forgets the whole saved map (rpg_map_cache_clear), as before; no fingerprint yet forgets the whole map too;
--  * a card that is a place, before or after the change: a land (place_level 2 or less, it may change the ground of the
--    Continent grid and so every river) forgets the whole map; a smaller place forgets the saved grids of every level
--    that reach its box, grown by map_town_clear (towns keep clear of places), the World grid with them, and the saved
--    roads everywhere (roads keep off rough places), then saves the World and Continent grids again in the background
--    as a clear does. Other cards (creatures, objects) never change the ground.
-- One trigger a kind of change (a trigger with change tables takes one event); each IF reads only the rows its event has.
DECLARE
  v_all text; v_road text; v_fp jsonb; v_whole boolean := false; v_local boolean := false; v_clear double precision;
BEGIN
  IF TG_TABLE_NAME = 'rpg_settings' THEN
    SELECT md5(coalesce(string_agg(s.key || '=' || s.value, ';' ORDER BY s.key) FILTER (WHERE s.key NOT LIKE 'map\_road\_%'), '')),
           md5(coalesce(string_agg(s.key || '=' || s.value, ';' ORDER BY s.key) FILTER (WHERE s.key LIKE 'map\_road\_%'), ''))
      INTO v_all, v_road
      FROM public.rpg_settings s
     WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key LIKE 'map\_%';
    SELECT m.notes -> 'fp' INTO v_fp FROM public.rpg_map_cache m WHERE m.level = -1 AND m.gx = 0 AND m.gy = 0;
    IF v_fp IS NULL OR v_fp ->> 'all' IS DISTINCT FROM v_all THEN
      PERFORM public.rpg_map_cache_clear();
    ELSIF v_fp ->> 'road' IS DISTINCT FROM v_road THEN
      UPDATE public.rpg_map_cache m SET notes = m.notes - 'roads' - 'houses' - 'streets'
       WHERE m.notes ?| ARRAY['roads', 'houses', 'streets'];
    END IF;
    INSERT INTO public.rpg_map_cache (level, gx, gy, kinds, places, notes)
    VALUES (-1, 0, 0, '{}', '{}', jsonb_build_object('fp', jsonb_build_object('all', v_all, 'road', v_road)))
    ON CONFLICT (level, gx, gy) DO UPDATE SET notes = EXCLUDED.notes;
    RETURN NULL;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS rpg_watch_box (x0 double precision, y0 double precision, x1 double precision, y1 double precision, lv integer) ON COMMIT DROP;
  DELETE FROM rpg_watch_box WHERE true;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    INSERT INTO rpg_watch_box SELECT n.place_x - coalesce(n.place_w, 0) / 2.0, n.place_y - coalesce(n.place_h, 0) / 2.0,
                                     n.place_x + coalesce(n.place_w, 0) / 2.0, n.place_y + coalesce(n.place_h, 0) / 2.0, n.place_level
                                FROM new_rows n WHERE n.place_x IS NOT NULL;
  END IF;
  IF TG_OP IN ('DELETE', 'UPDATE') THEN
    INSERT INTO rpg_watch_box SELECT o.place_x - coalesce(o.place_w, 0) / 2.0, o.place_y - coalesce(o.place_h, 0) / 2.0,
                                     o.place_x + coalesce(o.place_w, 0) / 2.0, o.place_y + coalesce(o.place_h, 0) / 2.0, o.place_level
                                FROM old_rows o WHERE o.place_x IS NOT NULL;
  END IF;
  -- an update that leaves every place field as it was (a name, lore) still changes what a cell is called: local
  SELECT EXISTS (SELECT 1 FROM rpg_watch_box b WHERE coalesce(b.lv, 2) <= 2), EXISTS (SELECT 1 FROM rpg_watch_box)
    INTO v_whole, v_local;
  IF v_whole THEN
    PERFORM public.rpg_map_cache_clear();
  ELSIF v_local THEN
    SELECT coalesce((SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_clear')::double precision, 300)
      INTO v_clear;
    DELETE FROM public.rpg_map_cache m
     USING public.rpg_map_ladder() l
     WHERE m.level = l.level AND m.level >= 1
       AND EXISTS (SELECT 1 FROM rpg_watch_box b
                    WHERE (m.gx::double precision * l.span) <= b.x1 + v_clear AND ((m.gx + 1)::double precision * l.span) >= b.x0 - v_clear
                      AND (m.gy::double precision * l.span) <= b.y1 + v_clear AND ((m.gy + 1)::double precision * l.span) >= b.y0 - v_clear);
    UPDATE public.rpg_map_cache m SET notes = m.notes - 'roads' WHERE m.notes ? 'roads';
    -- the World and Continent grids saved again in the background, as a clear does
    PERFORM public.rpg_map_cache_warm_send();
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cache_clear()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Forgets the whole saved map (step 13; Peter 2026-10-06: a function so map changes update the stored layers): every
-- grid is worked out again the next time it is opened. Called when a setting or a place card changes
-- (rpg_map_cache_watch), and by any migration that changes how the ground of a cell is worked out. Returns how many
-- grids it forgot.
-- (Step 14d2) The World and Continent grids are then saved again at once in the background (rpg_map_cache_warm, two
-- calls sent when this change is committed, run as the service login), so the next World map does not have to save
-- them inside its own 8-second limit. (Step 14f1) A third call saves the downhill rivers alone first (level 0), so
-- a map opened meanwhile does not have to work them out.
DECLARE v_n integer;
BEGIN
  DELETE FROM public.rpg_map_cache WHERE true;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- (speed step 4) the warm-up has its own home now, shared with a place forgetting the grids near it
  PERFORM public.rpg_map_cache_warm_send();
  RETURN v_n;
END;
$function$;
