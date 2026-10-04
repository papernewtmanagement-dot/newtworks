-- Step 7a follow-up: rpg_map_costs reads the depth of the water only when a block holds water shallow enough to wade
-- (deep water is shaded full without it), so a world view does not read the rivers three times.
CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A block of cells of any grid with what each costs to cross: the cell as rpg_map_cells gives it, how hard it is inside
-- its ground (rpg_map_hard; nothing on a grid coarser than the City grid), and from those the percent of time it adds
-- (rpg_map_pct on its ground's range, rpg_map_band, read once a ground) and whether it is forest. Shallow water goes by
-- its depth instead (rpg_map_water, rpg_map_wade_pct), and its hard is how deep it is, up to swimming depth (deep
-- water 1), so deeper water is drawn darker. penalty = that percent; nothing for the sea and deep water. The one way a
-- block of the map is read with its costs: fight boards (rpg_fight_squares) and the Maps tab (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the depth of the water only when the block holds water shallow enough to wade (deep water is shaded full)
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1) ELSE h.hard END
  FROM c
 CROSS JOIN sw
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
$function$;

