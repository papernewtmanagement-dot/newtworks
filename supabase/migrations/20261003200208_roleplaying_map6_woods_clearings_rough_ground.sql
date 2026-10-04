-- Roleplaying world map, corrections step 3 (Peter 2026-10-03): woods, clearings and rough ground at every zoom.
-- Below the Country grid the land rolls fade so fast that a close view was one flat sheet (Havenmark: 140 of 144
-- cells open land). Every grid from the Country grid down to the District grid now adds its own scatter, read from
-- its own three layers of cover rolls (part 3): open land turns to woods or rough ground, forest opens into
-- clearings, hills grow woods. Coarser grids decide first and what they show stays. The World and Continent grids are
-- unchanged. New: rpg_map_cover (the one home of what a cover roll does), five settings map_cover_*. Changed in
-- place: rpg_map_cells. Rule card world_map: one sentence on woods, clearings and rough ground. No drops, no table
-- changes.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cover_from', 3, 'The first grid that adds its own woods, clearings and rough ground (3 = the Country grid)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cover_to', 6, 'The last grid that adds its own woods, clearings and rough ground (6 = the District grid; the battle grid shows what the District grid set)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cover_wood', 40, 'Open land turns to woods, and hills grow woods, where the cover roll of a grid is this or more (about 1 cell in 8 at each grid)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cover_rough', 55, 'Open land turns to rough ground (hills) where the cover roll of a grid is minus this or less (about 1 cell in 17 at each grid)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cover_clear', 42, 'Forest opens into a clearing where the cover roll of a grid is minus this or less (about 1 cell in 8 at each grid)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_cover(p_kind text, p_rolls double precision[], p_wood double precision, p_rough double precision, p_clear double precision)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
-- The cover of a cell of unnamed land: its kind (land, forest, hills, mountains) after the scatter of every grid it
-- is read with (rpg_map_cells), coarsest grid first. The one home of what a cover roll does. p_rolls = the cover
-- roll of each grid at the cell, coarsest first:
--   open land  at or above p_wood (map_cover_wood, 40) turns to woods (forest); at or below minus p_rough (-55)
--              to rough ground (hills),
--   forest     at or below minus p_clear (-42) opens into a clearing (open land),
--   hills      at or above p_wood grow woods (forest),
--   mountains  stay mountains.
-- The rolls of one grid stand about 35 either side of 0, so each grid turns about 1 open cell in 8 to woods and 1
-- in 17 to rough ground, and opens about 1 forest cell in 8. A cell turned by a coarser grid can turn again at a
-- finer one. Open land with rolls 12 then 47 is woods (12 does nothing, 47 is 40 or more); with 47 then -50 it is a
-- clearing in those woods (-50 is -42 or less).
DECLARE
  v_kind text := p_kind;
  v      double precision;
BEGIN
  FOREACH v IN ARRAY coalesce(p_rolls, '{}'::double precision[]) LOOP
    IF v_kind = 'land' THEN
      v_kind := CASE WHEN v >= p_wood THEN 'forest' WHEN v <= -p_rough THEN 'hills' ELSE 'land' END;
    ELSIF v_kind = 'forest' THEN
      v_kind := CASE WHEN v <= -p_clear THEN 'land' ELSE 'forest' END;
    ELSIF v_kind = 'hills' THEN
      v_kind := CASE WHEN v >= p_wood THEN 'forest' ELSE 'hills' END;
    END IF;
  END LOOP;
  RETURN v_kind;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of any block of cells of any grid of the world map, worked out when asked and never stored. The one
-- home of what a cell is; a single square under a piece is the same call at the battle grid, 1 by 1.
-- x, y = the cell, counted across the whole world at that level. p_x0, p_y0 = the first cell of the block.
-- kind, in this order:
--   sea        its height (rpg_map_heights) is below the sea level. The sea stays sea under every place.
--   place      its center lies inside a place card with ground of its own (a movement penalty), by the natural
--              edge of that place (rpg_map_within); place_id = the smallest such card. A place fills cells of a
--              grid when its oval covers the center of the cell its own center falls in; only places that fill
--              are ground.
--   mountains  unnamed land whose ground roll (rpg_map_blend, part 1) is within map_mountain_band (6.1) of the
--              middle: mountains run in chains along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- Then the cover of unnamed land (rpg_map_cover): every grid from the Country grid (map_cover_from, 3) down to the
-- District grid (map_cover_to, 6) that this grid reaches adds its own scatter of woods, clearings and rough ground,
-- read from the three layers of cover rolls of that grid (rpg_map_rolls, part 3), coarsest grid first. What a coarser
-- grid shows stays; each finer grid adds smaller patches. The World and Continent grids have no cover.
-- A place with no movement penalty (a continent, a country) only names the land and never changes a cell.
-- marks = the places with ground that reach into a land cell but are too small or too thin to fill any cell of
-- this grid, smallest first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this
-- grid is about are marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is
-- not marked on a Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_wood')::double precision AS wood,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_rough')::double precision AS rough,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_clear')::double precision AS clear,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_from')::integer AS cover_from,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_to')::integer AS cover_to,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge),
     pl AS MATERIALIZED (
       -- The place cards with ground whose edge can reach the block: the oval grown by how far the edge may wander
       -- (rpg_map_grown).
       SELECT q.id, q.place_x, q.place_y, q.place_w, q.place_h, q.area, q.fills
         FROM (SELECT c.id, c.place_x, c.place_y, c.place_w, c.place_h, c.place_level, c.place_w::bigint * c.place_h AS area,
                      public.rpg_map_covers(((c.place_x / lad.cell + 0.5) * lad.cell)::double precision, ((c.place_y / lad.cell + 0.5) * lad.cell)::double precision,
                                            c.place_x, c.place_y, c.place_w, c.place_h, lad.world) AS fills
                 FROM public.rpg_creatures c CROSS JOIN lad CROSS JOIN cfg
                WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
                  AND c.place_penalty IS NOT NULL
                  AND public.rpg_map_touches(p_x0::double precision * lad.cell, p_y0::double precision * lad.cell,
                                             (p_x0 + p_cols)::double precision * lad.cell, (p_y0 + p_rows)::double precision * lad.cell,
                                             c.place_x, c.place_y,
                                             public.rpg_map_grown(c.place_w, c.place_w, c.place_h, cfg.edge),
                                             public.rpg_map_grown(c.place_h, c.place_w, c.place_h, cfg.edge), lad.world)) q
        WHERE q.fills OR q.place_level <= p_level + 1),
     ck AS MATERIALIZED (
       -- The grids whose cover this grid reaches: from map_cover_from down to this grid, at most map_cover_to.
       SELECT k.level, k.cell FROM cfg CROSS JOIN public.rpg_map_ladder() k
        WHERE k.level BETWEEN cfg.cover_from AND least(p_level, cfg.cover_to)),
     cv AS MATERIALIZED (
       -- The cover rolls of each of those grids at every cell of the block, coarsest grid first; each grid reads only
       -- its own three layers (from layer 3 x its level - 2, down to points one of its cells apart).
       SELECT r.x, r.y, array_agg(r.value ORDER BY ck.level) AS rolls
         FROM ck CROSS JOIN LATERAL public.rpg_map_rolls(3, 3 * ck.level - 2, ck.cell, p_level, p_x0, p_y0, p_cols, p_rows) r
        GROUP BY r.x, r.y),
     g AS MATERIALIZED (
       SELECT h.x AS gx, h.y AS gy, h.height >= cfg.sea AS dry, lad.cell, lad.world,
              CASE WHEN h.height < cfg.sea THEN 'sea'
                   WHEN cv.rolls IS NULL THEN b.kind
                   ELSE public.rpg_map_cover(b.kind, cv.rolls, cfg.wood, cfg.rough, cfg.clear) END AS kind
         FROM lad CROSS JOIN cfg
        CROSS JOIN public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h
         JOIN public.rpg_map_blend(1, p_level, p_x0, p_y0, p_cols, p_rows) r ON r.x = h.x AND r.y = h.y
        CROSS JOIN LATERAL (SELECT CASE WHEN abs(r.value) < cfg.mountains THEN 'mountains'
                                        WHEN abs(r.value) < cfg.hills THEN 'hills'
                                        WHEN r.value >= cfg.forest THEN 'forest'
                                        ELSE 'land' END AS kind) b
         LEFT JOIN cv ON cv.x = h.x AND cv.y = h.y),
     hit AS MATERIALIZED (
       -- Every cell with every place it belongs to. A place that fills cells holds the cells inside its natural edge
       -- (rpg_map_within); a smaller one marks the cells its oval reaches into.
       SELECT w.x AS gx, w.y AS gy, p.id, p.area, true AS fills
         FROM pl p CROSS JOIN LATERAL public.rpg_map_within(p.id, p_level, p_x0, p_y0, p_cols, p_rows) w
        WHERE p.fills
       UNION ALL
       SELECT g.gx, g.gy, p.id, p.area, false
         FROM g JOIN pl p
           ON NOT p.fills
          AND public.rpg_map_touches(g.gx::double precision * g.cell, g.gy::double precision * g.cell,
                                     (g.gx + 1)::double precision * g.cell, (g.gy + 1)::double precision * g.cell,
                                     p.place_x, p.place_y, p.place_w, p.place_h, g.world))
SELECT g.gx, g.gy,
       CASE WHEN NOT g.dry THEN 'sea'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind
 ORDER BY g.gy, g.gx;
$function$;

REVOKE ALL ON FUNCTION public.rpg_map_cover(text, double precision[], double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_cover(text, double precision[], double precision, double precision, double precision) TO service_role;

UPDATE public.rpg_rules
   SET body = replace(body, 'Open land has penalty 0, forest 1, hills 1 and mountains 2.', 'Open land has penalty 0, forest 1, hills 1 and mountains 2. Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, so a square of it costs 1 + 1 = 2.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map';

