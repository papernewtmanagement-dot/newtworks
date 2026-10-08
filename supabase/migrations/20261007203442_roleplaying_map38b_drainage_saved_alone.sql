-- Step 14f1 follow-up: the downhill rivers are saved by their own background call only (level 0), so the World call
-- no longer holds that row and the two never wait on each other (the first save after map38 timed out on the lock).
CREATE OR REPLACE FUNCTION public.rpg_map_cache_warm(p_level integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Saves every grid of the World grid (1) or the Continent grid (2) not saved yet (step 14d2, 2026-10-07): the whole
-- level through rpg_map_cache_fill, the one home of saving a grid. Called in the background right after the saved map is
-- cleared (rpg_map_cache_clear), so the World map is never the one to pay for saving them: that takes about 9 seconds,
-- past the 8 a login may run a read, and the World map then failed with a timeout. Finer levels are saved as they are
-- opened, as before (one grid at a time is quick). Returns how many grids it saved; nothing for any other level.
-- (Step 14d4) The World grid's row also keeps the greatest cities of the world (notes: cities), the
-- map_world_city_count (8) great cities with the most people, read off the whole Continent grid (rpg_map_towns: about
-- 9 seconds, so only here, never while a map is opened); the World map shows them (rpg_map_view_block).
-- (Step 14f1) Called for level 0 it keeps the downhill rivers and great lakes of the Continent grid instead
-- (rpg_map_drain_make, about 4 seconds) on a row of their own (level 0), where rpg_map_drainage reads them, and returns
-- 1; that call runs alone, so it is saved within seconds of a clear (the World and Continent calls work them out for
-- themselves meanwhile and never wait on it).
DECLARE v_n integer;
BEGIN
  IF p_level NOT IN (0, 1, 2) THEN
    RETURN 0;
  END IF;
  IF p_level = 0 THEN
    -- (step 14f1) the downhill rivers and great lakes
    INSERT INTO public.rpg_map_cache (level, gx, gy, kinds, places, notes)
    SELECT 0, 0, 0, '{}', '{}', jsonb_build_object('drain', public.rpg_map_drain_make())
     WHERE NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = 0 AND m.gx = 0 AND m.gy = 0)
    ON CONFLICT (level, gx, gy) DO NOTHING;
    RETURN 1;
  END IF;
  v_n := (SELECT public.rpg_map_cache_fill(p_level, 0, 0, l.across::integer, l.down::integer) FROM public.rpg_map_ladder() l WHERE l.level = p_level);
  IF p_level = 1 THEN
    UPDATE public.rpg_map_cache m
       SET notes = jsonb_build_object('cities', coalesce(
             (SELECT jsonb_agg(to_jsonb(t) - 'shape' ORDER BY t.people DESC, t.id)
                FROM (SELECT t.* FROM public.rpg_map_ladder() l
                       CROSS JOIN LATERAL public.rpg_map_towns(2, 0, 0, l.across::integer, l.down::integer,
                                                               (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) FROM public.rpg_map_cells(2, 0, 0, l.across::integer, l.down::integer) c)) t
                      WHERE l.level = 2 AND t.kind = 'great_city'
                      ORDER BY t.people DESC, t.id
                      LIMIT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_world_city_count')::integer) t),
             '[]'::jsonb))
     WHERE m.level = 1 AND m.notes IS NULL;
  END IF;
  RETURN v_n;
END;
$function$;
