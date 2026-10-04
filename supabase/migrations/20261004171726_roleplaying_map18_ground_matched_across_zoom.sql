-- Roleplaying world map step 9 (Peter 2026-10-04 13:44, his go 16:45): ground matched across zoom. Every grid coarser
-- than the battle grid reads the land from the grid under it: 9 points in each cell, the cell taking the ground most
-- of them hold. No drops, no table changes. New: rpg_map_rolls_on, rpg_map_heights_on (bodies moved from
-- rpg_map_rolls and rpg_map_heights, which now call them and read exactly as before), rpg_map_nature (the ground the
-- land makes, moved out of rpg_map_cells). Changed: rpg_map_cells (the land part reads rpg_map_nature).

CREATE OR REPLACE FUNCTION public.rpg_map_rolls_on(p_part integer, p_first integer, p_fine integer, p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, value double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The layered rolls of the world map, read at the center of every cell in a block of an even spread of points. The one
-- home of how the fixed-seed rolls of the map (rpg_map_roll) are layered and blended; worked out when asked and
-- never stored. p_part picks the set of rolls: 0 is the height of the ground (rpg_map_heights), 1 is the kind of
-- ground (rpg_map_cells: mountains, hills, forest), 2 is how far the edge of a place wanders (rpg_map_within).
-- Part p uses roll layers p x 100 + 1 and up.
-- The layers are those of rpg_map_layers down to grid p_deep: three a grid, the points of each 2 or 3 times
-- closer than those of the layer before. Only the layers from p_first on are read, and only those whose points are
-- at least p_fine squares apart. The land reads every layer (p_first 1, p_fine 1: rpg_map_blend). The edge of a
-- place starts at the layer that fits its size and stops at bumps of p_fine squares. A layer is read by blending
-- the four rolls around the cell center, and a roll counts as its number less 50.5.
-- The first map_full_layers layers read (2) count in full; each layer after counts map_detail_share (0.6) of the
-- one before: 1, 1, 0.6, 0.36, 0.216 and so on. Rolls of 80 and 30 on the first two layers alone give 29.5 - 20.5
-- = 9. So the first layers read set the big shapes and each layer down adds finer shape.
-- A whole block is one call so that every roll is made once (rl) and shared by all the cells around it. The rolls
-- stay in one list outside the joins. What a layer adds at a cell is rounded to a whole number of 2^30ths (about a
-- billionth), so the layers add up to exactly the same number in whatever order they are added. The map wraps
-- east to west; north and south it stops at the edge.
-- Step 9 (2026-10-04): the body of rpg_map_rolls moved here unchanged but for two numbers it now takes, so the same rolls
-- can be read on any even spread of points, not only at the centers of the cells of one grid. p_cell = squares from
-- one point to the next (a grid of the ladder: its cell; a closer spread: fewer squares); p_deep = the finest grid
-- whose layers are read. Cells are counted on that spread: cell x has its center at (x + 0.5) x p_cell squares.
-- rpg_map_rolls is this read with p_deep = the grid and p_cell = its cell, so every grid reads exactly as before.
-- A coarse grid reads the land from the grid under it on a spread of three points to a cell (rpg_map_cells).
WITH RECURSIVE cfg AS (
       SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers,
              p_cell AS cell),
     wt(n, w) AS (
       -- What each layer counts, by multiplying one layer at a time so the numbers are the same on any machine.
       SELECT 1, 1::double precision
       UNION ALL
       SELECT wt.n + 1, CASE WHEN wt.n + 1 > cfg.full_layers THEN wt.w * cfg.share ELSE wt.w END
         FROM wt CROSS JOIN cfg
        WHERE wt.n < 3 * p_deep),
     lay AS MATERIALIZED (
       -- One row a layer that is read, coarsest first. n = its number; r = its place among the layers read; f =
       -- cells of this grid from one of its points to the next; nx, ny = its points around and down the world; wt =
       -- what it counts, by r; a_lo, b_lo = the first point the block needs; wd, ht = points across and down the
       -- block; off = the rolls of the layers before it.
       SELECT q.n, q.f, q.nx, q.ny, wt.w AS wt, q.a_lo, q.b_lo, q.wd, q.ht,
              (sum(q.wd * q.ht) OVER (ORDER BY q.n) - q.wd * q.ht)::integer AS off
         FROM (SELECT y.n, k.f, y.nx, y.ny, row_number() OVER (ORDER BY y.n) AS r,
                      floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer AS a_lo,
                      floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer AS b_lo,
                      floor((p_x0 + p_cols - 0.5::double precision) / k.f - 0.5)::integer - floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS wd,
                      floor((p_y0 + p_rows - 0.5::double precision) / k.f - 0.5)::integer - floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS ht
                 FROM cfg CROSS JOIN public.rpg_map_layers() y
                CROSS JOIN LATERAL (SELECT y.gap::double precision / cfg.cell AS f) k
                WHERE y.level <= p_deep AND y.n >= p_first AND y.gap >= p_fine) q
         JOIN wt ON wt.n = q.r),
     rl AS MATERIALIZED (
       -- Every roll the block needs, made once and kept in one list: layer by layer, each layer row by row.
       SELECT ARRAY(SELECT public.rpg_map_roll(cfg.seed, p_part * 100 + l.n, mod(mod(l.a_lo + i, l.nx) + l.nx, l.nx), least(greatest(l.b_lo + j, 0), l.ny - 1))
                      FROM cfg CROSS JOIN lay l CROSS JOIN LATERAL generate_series(0, l.ht - 1) AS j CROSS JOIN LATERAL generate_series(0, l.wd - 1) AS i
                     ORDER BY l.n, j, i) AS rolls),
     ax AS MATERIALIZED (
       -- One row a layer and column of the block. i = where the point just west of the cell center sits in a row
       -- of the rolls of the layer; sx = how far east of that point the center is, eased (0 on the point, 1 on the next).
       SELECT l.n, gx, a.a - l.a_lo AS i, (u.u - a.a) * (u.u - a.a) * (3 - 2 * (u.u - a.a)) AS sx
         FROM lay l CROSS JOIN generate_series(p_x0, p_x0 + p_cols - 1) AS gx
        CROSS JOIN LATERAL (SELECT (gx + 0.5::double precision) / l.f - 0.5 AS u) u
        CROSS JOIN LATERAL (SELECT floor(u.u)::integer AS a) a),
     ay AS MATERIALIZED (
       -- The same down the block. j = where the row of points just north of the cell center starts in the list of
       -- rolls; sy = how far south of that row the center is, eased.
       SELECT l.n, gy, l.off + (b.b - l.b_lo) * l.wd AS j, (v.v - b.b) * (v.v - b.b) * (3 - 2 * (v.v - b.b)) AS sy
         FROM lay l CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy
        CROSS JOIN LATERAL (SELECT (gy + 0.5::double precision) / l.f - 0.5 AS v) v
        CROSS JOIN LATERAL (SELECT floor(v.v)::integer AS b) b)
-- One row a cell: the sum over the layers of what each adds at the cell, from the four rolls around it.
SELECT ax.gx, ay.gy,
       sum(floor(l.wt * (((SELECT rl.rolls FROM rl)[ay.j + ax.i + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + 2] * ax.sx) * (1 - ay.sy)
                       + ((SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 2] * ax.sx) * ay.sy - 50.5)
                 * 1073741824 + 0.5) / 1073741824)
  FROM lay l
  JOIN ax ON ax.n = l.n
  JOIN ay ON ay.n = l.n
 GROUP BY ax.gx, ay.gy;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_rolls(p_part integer, p_first integer, p_fine integer, p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, value double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The layered rolls of the world map, read at the center of every cell in a block of cells of one grid, with every
-- layer down to that grid. How the rolls are layered, blended and weighed has one home, rpg_map_rolls_on (step 9);
-- this is that function on the cells of grid p_level. p_part picks the set of rolls: 0 height (rpg_map_heights), 1
-- kind of ground (rpg_map_cells), 2 place edges (rpg_map_within), 3 cover, 4 warmth, 5 wetness, and so on.
SELECT r.x, r.y, r.value
  FROM public.rpg_map_rolls_on(p_part, p_first, p_fine, p_level,
                               (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
                               p_x0, p_y0, p_cols, p_rows) r;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_heights_on(p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How high the ground stands at the center of every cell in a block of an even spread of points p_cell squares apart,
-- with the layers down to grid p_deep whose points are at least p_cell squares apart (rpg_map_rolls_on; a grid of
-- the ladder has no finer layers than its own cell, so on its own cells it reads every layer down to it). The one home of land and sea: land where the height is at
-- or above the sea level (rpg_settings map_sea_level, 14.6), sea below it. Worked out when asked and never stored.
-- The height is the height rolls (part 0) less a pull toward the sea at the far north and south, so no land is cut
-- off by the top or bottom edge of the map: map_pole_pull (80) x how far the point is from the middle line toward
-- the edge (0 to 1), raised to the eighth power. Halfway to the edge that is 80 x 0.5^8 = 0.3; nine tenths of the
-- way it is 80 x 0.9^8 = 34. Step 9 (2026-10-04): the body of rpg_map_heights moved here; rpg_map_heights is this
-- read on the cells of one grid.
SELECT b.x, b.y, b.value - c.pole * ((e.e2 * e.e2) * (e.e2 * e.e2))
  FROM public.rpg_map_rolls_on(0, 1, p_cell, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) b
 CROSS JOIN (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_pole_pull')::double precision AS pole,
                    -- points down the whole world on this spread
                    (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 7)::double precision / p_cell AS down) c
 CROSS JOIN LATERAL (SELECT abs(2 * (b.y + 0.5::double precision) / c.down - 1) AS e1) d
 CROSS JOIN LATERAL (SELECT d.e1 * d.e1 AS e2) e;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_heights(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How high the ground stands at the center of every cell in a block of cells of one grid of the world map, with the
-- layers down to that grid. The one home of land and sea is rpg_map_heights_on (step 9); this is that read on the
-- cells of grid p_level.
SELECT h.x, h.y, h.height
  FROM public.rpg_map_heights_on(p_level, (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
                                 p_x0, p_y0, p_cols, p_rows) h;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_nature(p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground the land itself makes (step 9, 2026-10-04): sea, the kind of unnamed ground, its cover and its climate,
-- at the center of every cell in a block of an even spread of points p_cell squares apart, read with the layers down
-- to grid p_deep whose points are at least p_cell squares apart (finer layers would not show between the points).
-- The one home of the ground of the land; places, rivers and lakes, towns and roads are laid over it by rpg_map_cells.
-- Moved out of rpg_map_cells. On the cells of one grid (p_deep = the grid, p_cell = its cell) it reads exactly what
-- rpg_map_cells read before; the battle grid reads it so, at every square. Every coarser grid reads it at 3 x 3
-- points in each of its cells, from the grid under it, and takes what most of them hold (rpg_map_cells).
-- kind, in this order:
--   sea        its height (rpg_map_heights_on) is below the sea level.
--   mountains  its ground roll (rpg_map_rolls_on, part 1) is within map_mountain_band (6.1) of the middle: mountains
--              run in chains along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- Then the cover (rpg_map_cover): every grid from the Country grid (map_cover_from, 3) down to the District grid
-- (map_cover_to, 6) that p_deep reaches adds its own scatter of woods, clearings and rough ground, read from the
-- three layers of cover rolls of that grid (part 3), coarsest grid first. The World and Continent grids have no cover.
-- Then the climate (rpg_map_climate, Peter 2026-10-03): snow and ice, tundra, pine forest, desert, grassy plains,
-- jungle and swamp. Warmth runs from 100 at the equator to 0 at the poles, moved by map_warmth_share of the warmth
-- rolls (part 4); wetness is the wetness rolls (part 5) moved by map_wet_band with the latitude. Both rolls are read
-- only from the layers whose points are at least map_climate_fine squares apart (one Continent cell), so a spot has
-- the same climate at every zoom; swamp also needs low ground. height = the height of the point.
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_wood')::double precision AS wood,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_rough')::double precision AS rough,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_clear')::double precision AS clear,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_from')::integer AS cover_from,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_to')::integer AS cover_to,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_climate_fine')::integer AS climate_fine,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_warmth_share')::double precision AS warmth_share,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wet_band')::double precision AS wet_band,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_ice_warmth')::double precision AS ice,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_tundra_warmth')::double precision AS tundra,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cold_warmth')::double precision AS cold,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hot_warmth')::double precision AS hot,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_desert_wet')::double precision AS desert,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_plains_wet')::double precision AS plains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_jungle_wet')::double precision AS jungle,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_taiga_wet')::double precision AS taiga,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swamp_wet')::double precision AS swamp_wet,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swamp_height')::double precision AS swamp_height),
     ck AS MATERIALIZED (
       -- The grids whose cover this grid reaches: from map_cover_from down to this grid, at most map_cover_to.
       SELECT k.level, k.cell FROM cfg CROSS JOIN public.rpg_map_ladder() k
        WHERE k.level BETWEEN cfg.cover_from AND least(p_deep, cfg.cover_to)),
     cv AS MATERIALIZED (
       -- The cover rolls of each of those grids at every cell of the block, coarsest grid first; each grid reads only
       -- its own three layers (from layer 3 x its level - 2, down to points one of its cells apart).
       SELECT r.x, r.y, array_agg(r.value ORDER BY ck.level) AS rolls
         FROM ck CROSS JOIN LATERAL public.rpg_map_rolls_on(3, 3 * ck.level - 2, greatest(ck.cell, p_cell), p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) r
        GROUP BY r.x, r.y),
     cl AS MATERIALIZED (
       -- The climate rolls of every cell of the block: warmth (part 4) and wetness (part 5), read only from the layers
       -- whose points are at least map_climate_fine squares apart.
       SELECT t.x, t.y, t.value AS warm, w.value AS wet
         FROM cfg
        CROSS JOIN LATERAL public.rpg_map_rolls_on(4, 1, greatest(cfg.climate_fine, p_cell), p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) t
         JOIN LATERAL public.rpg_map_rolls_on(5, 1, greatest(cfg.climate_fine, p_cell), p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) w ON w.x = t.x AND w.y = t.y)
SELECT h.x, h.y,
       CASE WHEN h.height < cfg.sea THEN 'sea'
            ELSE public.rpg_map_climate(CASE WHEN cv.rolls IS NULL THEN b.kind ELSE public.rpg_map_cover(b.kind, cv.rolls, cfg.wood, cfg.rough, cfg.clear) END,
                                        100 * (1 - e.e) + cfg.warmth_share * cl.warm, cl.wet + cfg.wet_band * cos(3 * pi() * e.e), h.height - cfg.sea,
                                        cfg.ice, cfg.tundra, cfg.cold, cfg.hot, cfg.desert, cfg.plains, cfg.jungle, cfg.taiga,
                                        cfg.swamp_wet, cfg.swamp_height) END,
       h.height
  FROM cfg
 CROSS JOIN public.rpg_map_heights_on(p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) h
  JOIN public.rpg_map_rolls_on(1, 1, p_cell, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) r ON r.x = h.x AND r.y = h.y
 CROSS JOIN LATERAL (SELECT CASE WHEN abs(r.value) < cfg.mountains THEN 'mountains'
                                 WHEN abs(r.value) < cfg.hills THEN 'hills'
                                 WHEN r.value >= cfg.forest THEN 'forest'
                                 ELSE 'land' END AS kind) b
  LEFT JOIN cv ON cv.x = h.x AND cv.y = h.y
  JOIN cl ON cl.x = h.x AND cl.y = h.y
 -- e = how far the point is from the equator toward a pole, 0 to 1 (points down the whole world: the squares down
 -- the battle grid over p_cell)
 CROSS JOIN LATERAL (SELECT abs(2 * (h.y + 0.5::double precision) / ((SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 7)::double precision / p_cell) - 1) AS e) e
 ORDER BY h.y, h.x;
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
--   sea        the land (below) is sea there: its height is below the sea level. The sea stays sea under every place.
--   water      rivers and lakes on dry land (rpg_map_water): deep where the middle of the cell is deeper than
--   deep       map_swim_depth (1.2 m, chest-deep: it is swum), else water (it is waded). Water lies over places
--              and every ground; the cell keeps its place (place_id) so a river in the Old Forest is in it.
--   place      its center lies inside a place card with ground of its own (a movement penalty), by the natural
--              edge of that place (rpg_map_within); place_id = the smallest such card. A place fills cells of a
--              grid when its oval covers the center of the cell its own center falls in; only places that fill
--              are ground.
--   town       its center lies inside a village, town or city (rpg_map_town_cells; step 8): their streets and
--              yards. Only the City grid and finer: a coarser grid marks them instead (rpg_map_view_block).
--   road       the battle grid only: a highway, road or lane runs over the square (rpg_map_road_cells; step 8b), the
--   pass       middle of the square within half the width of the road from its line: road, or pass where the ground under
--              it is mountains (a road over a pass keeps its climb). A road over snow and ice is the snow and ice; where
--              a road meets a river or a lake it crosses it (a bridge, a ford or a ferry: road, ahead of the water); the
--              sea stops it. Coarser grids draw roads as lines instead.
--   the land  everything else: the ground the land makes (rpg_map_nature): sea, mountains, hills, forest, open
--              land, then woods, clearings and rough ground, then the climates. The battle grid reads it at every
--              square. Every coarser grid reads it from the grid under it (step 9, Peter 2026-10-04): 9 points in each
--              cell, three across and three down a third of a cell apart, read with the layers down to the next grid;
--              the cell takes the ground most of them hold (a tie goes to the ground nearer the middle of the cell).
--              So the coast, the chains, the woods and the climates of a coarse cell are what most of the ground under
--              it is, and zooming in keeps the borders in place, only finer.
-- A place with no movement penalty (a continent, a country) only names the land and never changes a cell.
-- marks = the places with ground that reach into a land cell but are too small or too thin to fill any cell of
-- this grid, smallest first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this
-- grid is about are marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is
-- not marked on a Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, l.down, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth')::double precision AS swim),
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
     sp AS (
       -- How the land is read (step 9): the battle grid at every square; a coarser grid at 3 x 3 points in each of its
       -- cells, a third of a cell apart, with the layers down to the grid under it.
       SELECT CASE WHEN p_level < 7 THEN 3 ELSE 1 END AS n, least(p_level + 1, 7) AS deep FROM (SELECT 1) one),
     pt AS MATERIALIZED (
       -- The ground of the land at every point read (rpg_map_nature), with the cell of this grid it lies in and how far
       -- it lies from the middle of that cell (in points, squared).
       SELECT q.gx, q.gy, q.kind, power(q.x - q.gx * sp.n - (sp.n - 1) / 2.0, 2) + power(q.y - q.gy * sp.n - (sp.n - 1) / 2.0, 2) AS off
         FROM lad CROSS JOIN sp
        CROSS JOIN LATERAL (SELECT nt.x, nt.y, nt.kind, floor(nt.x::double precision / sp.n)::integer AS gx, floor(nt.y::double precision / sp.n)::integer AS gy
                              FROM public.rpg_map_nature(sp.deep, lad.cell / sp.n, p_x0 * sp.n, p_y0 * sp.n, p_cols * sp.n, p_rows * sp.n) nt) q),
     g AS MATERIALIZED (
       -- Each cell takes the ground most of its points hold; a tie goes to the ground whose points lie nearer the
       -- middle of the cell, then by name. So a cell shows what most of the grid under it shows, and zooming in keeps
       -- every border where it was, only finer.
       SELECT DISTINCT ON (c.gx, c.gy) c.gx, c.gy, c.kind <> 'sea' AS dry, lad.cell, lad.world, c.kind
         FROM lad CROSS JOIN (SELECT pt.gx, pt.gy, pt.kind, count(*) AS votes, sum(pt.off) AS off FROM pt GROUP BY pt.gx, pt.gy, pt.kind) c
        ORDER BY c.gx, c.gy, c.votes DESC, c.off, c.kind),
     wt AS MATERIALIZED (
       -- rivers and lakes on the block (rpg_map_water)
       SELECT w.x, w.y, w.depth FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w),
     tc AS MATERIALIZED (
       -- the cells inside a village, town or city (rpg_map_town_cells): the City grid and finer
       SELECT t.x, t.y FROM public.rpg_map_town_cells(p_level, p_x0, p_y0, p_cols, p_rows) t WHERE p_level >= 5),
     rd AS MATERIALIZED (
       -- the squares a road runs over (rpg_map_road_cells): the battle grid only
       SELECT r.x, r.y FROM public.rpg_map_road_cells(p_level, p_x0, p_y0, p_cols, p_rows) r WHERE p_level = 7),
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
            WHEN rd.x IS NOT NULL AND wt.depth > 0 THEN 'road'
            WHEN wt.depth >= cfg.swim THEN 'deep'
            WHEN wt.depth > 0 THEN 'water'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            WHEN tc.x IS NOT NULL THEN 'town'
            WHEN rd.x IS NOT NULL AND g.kind = 'mountains' THEN 'pass'
            WHEN rd.x IS NOT NULL AND g.kind <> 'ice' THEN 'road'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN tc ON tc.x = g.gx AND tc.y = g.gy
  LEFT JOIN rd ON rd.x = g.gx AND rd.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim, tc.x, rd.x
 ORDER BY g.gy, g.gx;
$function$;

REVOKE ALL ON FUNCTION public.rpg_map_rolls_on(integer, integer, integer, integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_heights_on(integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_nature(integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_rolls_on(integer, integer, integer, integer, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_heights_on(integer, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_nature(integer, integer, integer, integer, integer, integer) TO service_role;

UPDATE public.rpg_rules SET body = replace(body,
'The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board.',
'The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board. Each cell of a grid shows the ground most of the land inside it holds, so zooming in keeps every coast, mountain chain, wood and climate where it was, only finer.'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('Each cell of a grid shows the ground most of the land inside it holds' IN body) = 0;

