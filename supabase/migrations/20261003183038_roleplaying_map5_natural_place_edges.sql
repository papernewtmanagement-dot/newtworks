-- Roleplaying world map, corrections step 2 (Peter 2026-10-03): natural edges on places.
-- Old Forest looked very cleanly laid out because a place was its perfect oval. A place with ground of its own now
-- has an edge that wanders in and out of the oval, rolled the way the coasts of the world are, starting at the
-- layer of rolls that fits the size of the place. One edge for the picture, walking and fights: rpg_map_within.
-- New: rpg_map_grown (the quick test before an edge is asked), rpg_map_layers (how the layers are spaced), rpg_map_rolls (the layered rolls from any layer on; the body of
-- rpg_map_blend moved here unchanged and rpg_map_blend now reads it from layer 1), rpg_map_within. Changed in place:
-- rpg_map_blend, rpg_map_cells, rpg_map_place_at, rpg_map_haunters, rpg_map_view. No table or column changes, no
-- drops. Three settings: map_edge_share, map_edge_bump, map_edge_fine. Rule card world_map: ground not found yet is
-- now dark on the page, so "stays blank" reads "stays dark".

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_edge_share', 0.5, 'The edge of a place wanders in and out of its oval by up to this share of half its short side (0.5: Old Forest is 8 miles across the short way, so its edge moves up to 2 miles)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_edge_bump', 0.5, 'The biggest bumps on the edge of a place are rolled on points no farther apart than this share of its short side (0.5: half)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_edge_fine', 6, 'The smallest bumps on the edge of a place are rolled on points this many squares apart (6 squares is 22 feet); a place too thin for bumps, like a road, keeps a clean edge')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_grown(p_side integer, p_w integer, p_h integer, p_share double precision)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- One side of the oval of a place, grown by how far its edge may wander at both ends: the side plus p_share
-- (map_edge_share) of the short side. No point outside the grown oval is in the place, so the grown oval is the
-- quick test before the edge itself is asked (rpg_map_within). Old Forest, 28,779 by 11,512 squares at share 0.5:
-- 28,779 + 5,756 = 34,535 wide and 11,512 + 5,756 = 17,268 tall.
SELECT ceil(p_side + p_share * least(p_w, p_h))::integer;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_layers()
 RETURNS TABLE(n integer, level integer, gap integer, nx integer, ny integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- Every layer of the fixed-seed rolls of the world map, coarsest first. The one home of how the layers are spaced.
-- Each grid of the ladder (rpg_map_ladder) adds three layers. The world grid rolls on points 3 cells apart, 2 cells
-- apart and on every cell; every grid below it rolls on points 6 cells apart, 3 apart and on every cell. So the
-- points of each layer are 2 or 3 times closer than those of the layer before: from a quarter of the way round the
-- world (layer 1, 8,957,952 squares) down to one square (layer 21).
-- n = the number of the layer; level = the grid it belongs to; gap = squares from one of its points to the next;
-- nx, ny = its points around and down the world. Layer 11 belongs to the Region grid and has a gap of 5,184 squares
-- (3 Region cells, 3.6 miles).
SELECT (l.level - 1) * 3 + v.i, l.level, g.m * l.cell, l.across / g.m, l.down / g.m
  FROM public.rpg_map_ladder() l
 CROSS JOIN (VALUES (1, 3, 6), (2, 2, 3), (3, 1, 1)) AS v(i, world_gap, below_gap)
 CROSS JOIN LATERAL (SELECT CASE WHEN l.level = 1 THEN v.world_gap ELSE v.below_gap END AS m) g;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_rolls(p_part integer, p_first integer, p_fine integer, p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, value double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The layered rolls of the world map, read at the center of every cell in a block of cells of one grid. The one
-- home of how the fixed-seed rolls of the map (rpg_map_roll) are layered and blended; worked out when asked and
-- never stored. p_part picks the set of rolls: 0 is the height of the ground (rpg_map_heights), 1 is the kind of
-- ground (rpg_map_cells: mountains, hills, forest), 2 is how far the edge of a place wanders (rpg_map_within).
-- Part p uses roll layers p x 100 + 1 and up.
-- The layers are those of rpg_map_layers down to the grid asked for: three a grid, the points of each 2 or 3 times
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
WITH RECURSIVE cfg AS (
       SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers,
              (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) AS cell),
     wt(n, w) AS (
       -- What each layer counts, by multiplying one layer at a time so the numbers are the same on any machine.
       SELECT 1, 1::double precision
       UNION ALL
       SELECT wt.n + 1, CASE WHEN wt.n + 1 > cfg.full_layers THEN wt.w * cfg.share ELSE wt.w END
         FROM wt CROSS JOIN cfg
        WHERE wt.n < 3 * p_level),
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
                CROSS JOIN LATERAL (SELECT y.gap / cfg.cell AS f) k
                WHERE y.level <= p_level AND y.n >= p_first AND y.gap >= p_fine) q
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

CREATE OR REPLACE FUNCTION public.rpg_map_blend(p_part integer, p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, value double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The layered rolls of the world map as the land reads them: every layer from the first, down to one square, at the
-- center of every cell in a block of cells of one grid. Part 0 is the height of the ground (rpg_map_heights), part 1
-- the kind of ground (rpg_map_cells). How the rolls are layered, blended and weighed has one home, rpg_map_rolls;
-- this is that function read from layer 1 with no smallest gap.
SELECT r.x, r.y, r.value FROM public.rpg_map_rolls(p_part, 1, 1, p_level, p_x0, p_y0, p_cols, p_rows) r;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_within(p_place uuid, p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block of one grid whose centers lie inside a place. The one home of where the edge of a place
-- runs: the picture (rpg_map_cells), walking and fights (through rpg_map_cells), the place a square is in
-- (rpg_map_place_at), haunts (rpg_map_haunters) and what a known place shows (rpg_map_view) all ask here.
-- A place card is an oval (place_x, place_y, place_w, place_h). A land that only names the ground (no movement
-- penalty: a continent, a country) keeps the oval as its edge. A place with ground of its own has a natural edge:
-- it wanders in and out of the oval by up to map_edge_share (0.5) of half the short side of the place, measured
-- along the line from the center of the place. Old Forest is 8 miles across the short way, so its edge moves up to
-- 0.5 x 4 = 2 miles either way.
-- How far it has wandered at a spot comes from the edge rolls there (rpg_map_rolls, part 2), read the way the land
-- is, but starting at the first layer whose points are no farther apart than map_edge_bump (0.5) of the short side
-- and stopping at points map_edge_fine (6) squares apart: Old Forest (11,512 squares across the short way) starts
-- at layer 11 (points 5,184 squares apart). The rolls there, as a share of 49.5 (the farthest one roll can stand
-- from the middle) and never past 1 either way, times the share: rolls adding up to 24.75 push the edge out half of
-- what it may, 1 mile for Old Forest; -49.5 or less pulls it in the full 2 miles.
-- On a grid coarser than that first layer the oval is the edge (Old Forest on a Country grid), and a place too thin
-- for bumps of 6 squares keeps a clean edge at every grid (a road 8 squares wide). Nothing is stored.
-- x, y = the cell, counted across the whole world at that level, like rpg_map_cells.
WITH lad AS (SELECT l.cell, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS share,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_bump')::double precision AS bump,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_fine')::integer AS fine),
     pc AS MATERIALIZED (
       -- The place, when its edge can reach the block at all (its oval grown by how far the edge may wander). half =
       -- half its short side; first = the first layer of its edge rolls on this grid, nothing when the oval is
       -- the edge here.
       SELECT c.place_x AS cx, c.place_y AS cy, c.place_w AS w, c.place_h AS h, lad.cell, lad.world, cfg.share, cfg.fine,
              least(c.place_w, c.place_h) / 2.0::double precision AS half,
              CASE WHEN c.place_penalty IS NOT NULL
                   THEN (SELECT min(y.n) FROM public.rpg_map_layers() y
                          WHERE y.level <= p_level AND y.gap >= cfg.fine AND y.gap <= least(c.place_w, c.place_h) * cfg.bump) END AS first
         FROM public.rpg_creatures c CROSS JOIN lad CROSS JOIN cfg
        WHERE c.id = p_place AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
          AND public.rpg_map_touches(p_x0::double precision * lad.cell, p_y0::double precision * lad.cell,
                                     (p_x0 + p_cols)::double precision * lad.cell, (p_y0 + p_rows)::double precision * lad.cell,
                                     c.place_x, c.place_y,
                                     public.rpg_map_grown(c.place_w, c.place_w, c.place_h, cfg.share),
                                     public.rpg_map_grown(c.place_h, c.place_w, c.place_h, cfg.share), lad.world)),
     r AS MATERIALIZED (
       -- The edge rolls at every cell of the block, only when the edge wanders on this grid.
       SELECT e.x, e.y, e.value
         FROM pc CROSS JOIN LATERAL public.rpg_map_rolls(2, pc.first, pc.fine, p_level, p_x0, p_y0, p_cols, p_rows) e
        WHERE pc.first IS NOT NULL)
-- dx, dy = from the center of the place to the center of the cell, the short way round the world; dist = that in
-- squares; d = the same as a share of the way to the oval (1 on the oval), so the oval lies dist / d squares out
-- along that line.
SELECT g.gx, g.gy
  FROM pc
 CROSS JOIN LATERAL (SELECT gx, gy, ((gx + 0.5) * pc.cell)::double precision AS px, ((gy + 0.5) * pc.cell)::double precision AS py
                       FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy) g
  LEFT JOIN r ON r.x = g.gx AND r.y = g.gy
 CROSS JOIN LATERAL (SELECT (g.px - pc.cx) - pc.world * floor((g.px - pc.cx) / pc.world + 0.5) AS dx, g.py - pc.cy AS dy) o
 CROSS JOIN LATERAL (SELECT sqrt(o.dx * o.dx + o.dy * o.dy) AS dist,
                            sqrt(power(o.dx / (pc.w / 2.0::double precision), 2) + power(o.dy / (pc.h / 2.0::double precision), 2)) AS d) q
 WHERE CASE WHEN pc.first IS NULL THEN public.rpg_map_covers(g.px, g.py, pc.cx, pc.cy, pc.w, pc.h, pc.world)
            WHEN q.d = 0 THEN true
            ELSE q.dist <= q.dist / q.d + pc.half * pc.share * greatest(-1, least(1, coalesce(r.value, 0) / 49.5)) END;
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
     g AS MATERIALIZED (
       SELECT h.x AS gx, h.y AS gy, h.height >= cfg.sea AS dry, r.value AS ground, lad.cell, lad.world
         FROM lad CROSS JOIN cfg
        CROSS JOIN public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h
         JOIN public.rpg_map_blend(1, p_level, p_x0, p_y0, p_cols, p_rows) r ON r.x = h.x AND r.y = h.y),
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
            WHEN abs(g.ground) < (SELECT cfg.mountains FROM cfg) THEN 'mountains'
            WHEN abs(g.ground) < (SELECT cfg.hills FROM cfg) THEN 'hills'
            WHEN g.ground >= (SELECT cfg.forest FROM cfg) THEN 'forest'
            ELSE 'land' END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.ground
 ORDER BY g.gy, g.gx;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_at(p_x integer, p_y integer)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The place a world square (from 1) lies in: the smallest place card that holds it, by the natural edge of the place
-- (rpg_map_within, the square asked as a block of one on the battle grid); a land that only names the ground
-- (Havenmark) when no smaller place does. In the Thornfields that is the Thornfields. Only the places whose grown
-- oval (rpg_map_grown) covers the square are asked for their edge.
SELECT p.id
  FROM public.rpg_creatures p
 CROSS JOIN (SELECT (SELECT max(l.level) FROM public.rpg_map_ladder() l) AS battle,
                    (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge) b
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL
   AND public.rpg_map_covers(p_x - 0.5::double precision, p_y - 0.5::double precision, p.place_x, p.place_y,
                             public.rpg_map_grown(p.place_w, p.place_w, p.place_h, b.edge), public.rpg_map_grown(p.place_h, p.place_w, p.place_h, b.edge), b.world)
   AND EXISTS (SELECT 1 FROM public.rpg_map_within(p.id, b.battle, p_x - 1, p_y - 1, 1, 1))
 ORDER BY p.place_w::bigint * p.place_h, p.id LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_haunters(p_x integer, p_y integer)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The creature cards that haunt a world square (counted from 1): every card whose haunt_ids name a place that holds
-- the square, by the natural edge of the place (rpg_map_within). Nothing when no haunt does. Only the haunts whose
-- grown oval (rpg_map_grown) covers the square are asked for their edge.
SELECT array_agg(DISTINCT c.id ORDER BY c.id)
  FROM public.rpg_creatures c
 CROSS JOIN LATERAL unnest(c.haunt_ids) AS h(id)
  JOIN public.rpg_creatures p ON p.id = h.id AND p.is_active AND p.place_w IS NOT NULL
 CROSS JOIN (SELECT (SELECT max(l.level) FROM public.rpg_map_ladder() l) AS battle,
                    (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge) b
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
   AND public.rpg_map_covers(p_x - 0.5::double precision, p_y - 0.5::double precision, p.place_x, p.place_y,
                             public.rpg_map_grown(p.place_w, p.place_w, p.place_h, b.edge), public.rpg_map_grown(p.place_h, p.place_w, p.place_h, b.edge), b.world)
   AND EXISTS (SELECT 1 FROM public.rpg_map_within(p.id, b.battle, p_x - 1, p_y - 1, 1, 1));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read, game master only: one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). p_level 1 is the world; a deeper grid is named by its level and by the cell of the grid
-- above that it fills, counted across the whole world: 3, 88, 41 is the Country grid inside cell 88, 41 of the
-- Continent grids.
-- Returns the grid (level, name, title, cols, rows, scale), the way back up (crumbs), the grid next door each way
-- (moves), every cell in reading order (x, y, its name like C5, kind sea / land / forest / hills / mountains /
-- place, place = the card it belongs to, marks = other place cards reaching into it, open = the grid inside it),
-- every place card (name, color, icon = the name of its map symbol, size, ground = its ground in words or nothing
-- when it only names the land, the place it is inside, level = the kind of place it is, view = the grid of its own
-- level around its center, listed = it belongs on this grid's list, spot = where to write its name on this grid:
-- its center from the top-left corner, then its width and height, all four in thousandths of a cell, or nothing
-- when the center is off the grid), list = what this grid lists, the places one level down that reach into it
-- (the world lists continents, a continent countries, a country regions, a region cities, a city districts, a
-- district battle grids; a battle grid lists nothing), within = the continent, country and so on that hold the
-- middle of this grid, biggest first (only places that name the land, the smallest of each kind), grounds = each
-- kind of unnamed ground with its name and, when it has one, its movement penalty in words, and the ladder of
-- grids in words.
-- The world also carries detail: every cell of the Continent grids inside it, 144 across and 72 down, one
-- character a cell (~ sea, . open land, t forest, h hills, m mountains, else the character numbered 256 + the
-- place's spot in detail.places, counted from 0), so the world is drawn as fine as the grids inside it.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped. journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
-- The kids login sees the same read, cut to what the group has found (Peter 2026-10-03, 2A: within sight of where a
-- piece walked, rpg_map_found) or knows (1A: Knowing a place at 1 or more shows all of it, rpg_map_known_places):
-- other cells come as kind unknown with no place, places and lands only once found or known, a place lore only once
-- known, creatures only within sight of a character, and nothing to add.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := coalesce(p_x, 0);
  v_y         integer := coalesce(p_y, 0);
  v_x0        integer := 0;
  v_y0        integer := 0;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_dc        integer;
  v_dr        integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_within    jsonb;
  v_grounds   jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_scale     text;
  v_journey   jsonb;
  v_gm        boolean;
  v_known     uuid[] := '{}';
  v_seen      jsonb := '{}';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_gm := public.family_is_parent();
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = coalesce(p_level, 1);
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF v_l.level = 1 THEN
    IF v_x <> 0 OR v_y <> 0 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  ELSE
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    IF v_x NOT BETWEEN 0 AND v_up_across - 1 OR v_y NOT BETWEEN 0 AND v_up_down - 1 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
    v_x0 := v_x * v_l.cols;
    v_y0 := v_y * v_l.rows;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_l.cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_l.rows)::bigint * v_l.cell;

  IF NOT v_gm THEN
    v_known := public.rpg_map_known_places();
    SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
      FROM public.rpg_map_found(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) f;
  END IF;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'x', c.x - v_x0 + 1, 'y', c.y - v_y0 + 1,
           'name', public.rpg_square_name(c.x - v_x0 + 1, c.y - v_y0 + 1),
           'kind', CASE WHEN k.seen THEN c.kind ELSE 'unknown' END, 'place', CASE WHEN k.seen THEN c.place_id END,
           'marks', CASE WHEN k.seen AND cardinality(c.marks) > 0 THEN to_jsonb(c.marks) END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || c.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(c.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_cells(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) c
    LEFT JOIN (SELECT DISTINCT w.x, w.y
                 FROM unnest(v_known) AS n(id)
                CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) w
                WHERE NOT v_gm) kn ON kn.x = c.x AND kn.y = c.y
   CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k;

  IF v_l.level = 1 THEN
    SELECT l.across, l.down INTO v_dc, v_dr FROM public.rpg_map_ladder() l WHERE l.level = 2;
    IF NOT v_gm THEN
      SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen FROM public.rpg_map_found(2, 0, 0, v_dc, v_dr) f;
    END IF;
    WITH kn AS MATERIALIZED (
           SELECT DISTINCT w.x, w.y
             FROM unnest(v_known) AS n(id)
            CROSS JOIN LATERAL public.rpg_map_within(n.id, 2, 0, 0, v_dc, v_dr) w
            WHERE NOT v_gm),
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM public.rpg_map_cells(2, 0, 0, v_dc, v_dr) c
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' ELSE CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.' WHEN 'forest' THEN 't'
                                                   WHEN 'hills' THEN 'h' WHEN 'mountains' THEN 'm'
                                                   ELSE chr(255 + array_position(u.ids, d.place_id)) END END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y))
      INTO v_detail
      FROM ln;
  END IF;

  SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                        ELSE jsonb_build_object(
                          'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                          'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                   ORDER BY l.level)
    INTO v_crumbs
    FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
   WHERE l.level <= v_l.level;

  v_scale := public.rpg_map_length_text(v_l.span)
          || CASE WHEN v_l.level = 1 THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_ground_text(c.place_forest, c.place_penalty) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', CASE WHEN v_gm OR c.id = ANY (v_known) THEN c.lore END,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text,
           'listed', c.place_level = v_l.level + 1
                     AND (public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                 c.place_x, c.place_y, c.place_w, c.place_h, v_world)
                          -- a place with ground whose natural edge reaches past its oval into this grid
                          OR (c.place_penalty IS NOT NULL AND EXISTS (SELECT 1 FROM public.rpg_map_within(c.id, v_l.level, v_x0, v_y0, v_l.cols, v_l.rows)))),
           'spot', CASE WHEN s.cx - v_gx0 >= 0 AND s.cx - v_gx0 < v_gx1 - v_gx0 AND c.place_y - v_gy0 >= 0 AND c.place_y - v_gy0 < v_gy1 - v_gy0
                        THEN jsonb_build_array(((s.cx - v_gx0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               ((c.place_y - v_gy0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_w::bigint * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_h::bigint * 1000 + v_l.cell / 2) / v_l.cell) END)
         ORDER BY c.sort_order, c.name)
    INTO v_places
    FROM public.rpg_creatures c
    JOIN public.rpg_map_ladder() f ON f.level = c.place_level
   -- its center, as the copy nearest the middle of this grid (the map wraps east to west)
   CROSS JOIN LATERAL (SELECT c.place_x + v_world::bigint * floor(((v_gx0 + v_gx1) / 2.0::double precision - c.place_x) / v_world + 0.5)::bigint AS cx) s
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
     AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id));

  SELECT coalesce(jsonb_agg(q.name ORDER BY q.place_level), '[]'::jsonb)
    INTO v_within
    FROM (SELECT DISTINCT ON (c.place_level) c.place_level, c.name
            FROM public.rpg_creatures c
           WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
             AND c.place_penalty IS NULL AND c.place_level <= v_l.level
             AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
             AND public.rpg_map_covers((v_gx0 + v_gx1) / 2.0::double precision, (v_gy0 + v_gy1) / 2.0::double precision,
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1) q;

  SELECT jsonb_strip_nulls(jsonb_build_object(
           'sea', jsonb_build_object('name', 'Sea'),
           'land', jsonb_build_object('name', 'Open land'),
           'forest', jsonb_build_object('name', 'Forest', 'penalty', CASE WHEN g.forest > 0 THEN public.rpg_map_ground_text(false, g.forest) END),
           'hills', jsonb_build_object('name', 'Hills', 'penalty', CASE WHEN g.hills > 0 THEN public.rpg_map_ground_text(false, g.hills) END),
           'mountains', jsonb_build_object('name', 'Mountains', 'penalty', CASE WHEN g.mountains > 0 THEN public.rpg_map_ground_text(false, g.mountains) END)))
    INTO v_grounds
    FROM (SELECT (SELECT r.penalty FROM public.rpg_map_ground('forest') r) AS forest,
                 (SELECT r.penalty FROM public.rpg_map_ground('hills') r) AS hills,
                 (SELECT r.penalty FROM public.rpg_map_ground('mountains') r) AS mountains) g;

  SELECT jsonb_agg(jsonb_build_object('name', l.name, 'line',
           public.rpg_map_length_text(l.span)
           || CASE WHEN l.level = 1 THEN ' around, cells of '
                   WHEN l.level = v_last THEN ' across, squares of '
                   ELSE ' across, cells of ' END
           || public.rpg_map_length_text(l.cell)) ORDER BY l.level)
    INTO v_ladder
    FROM public.rpg_map_ladder() l;

  SELECT jsonb_build_object(
           'id', s.id, 'name', s.name, 'status', s.status, 'time', public.rpg_map_time_text(s.clock),
           'current', s.current_participant_id,
           'log', coalesce((SELECT jsonb_agg(e.text ORDER BY e.created_at DESC)
                              FROM (SELECT e.text, e.created_at FROM public.rpg_events e
                                     WHERE e.session_id = s.id ORDER BY e.created_at DESC LIMIT 6) e), '[]'::jsonb),
           'pieces', coalesce((
             SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'placed', p.pos_x IS NOT NULL,
                      'creature', p.creature_id IS NOT NULL,
                      'out', CASE WHEN p.creature_id IS NOT NULL AND public.rpg_participant_out(p.id) THEN 'out of the fight' END,
                      'fight', public.rpg_map_in_fight(p.id),
                      'spot', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.sx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.sx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
                      'find', CASE WHEN p.pos_x IS NOT NULL AND v_l.level > 1 THEN v_l.level::text || '-' || (q.sx / v_l.span)::text || '-' || (q.sy / v_l.span)::text END,
                      'next', CASE WHEN s.status = 'active' AND p.id IS DISTINCT FROM s.current_participant_id AND p.next_tick IS NOT NULL
                                   THEN public.rpg_map_duration_text(greatest(p.next_tick - s.clock, 0)) END,
                      'day_left', public.rpg_map_duration_text(greatest(d.day - p.day_walk_ticks, 0)),
                      'walk_to', CASE WHEN p.walk_to_x IS NOT NULL THEN jsonb_build_array(p.walk_to_x, p.walk_to_y) END,
                      'to_go', CASE WHEN p.walk_to_x IS NOT NULL AND p.pos_x IS NOT NULL
                                    THEN public.rpg_map_length_text((SELECT w.steps FROM public.rpg_map_line(q.sx::integer, q.sy::integer, p.walk_to_x - 1, p.walk_to_y - 1) w)) END))
                    ORDER BY p.next_tick NULLS LAST, p.turn_order, p.created_at)
               FROM public.rpg_session_participants p
               LEFT JOIN public.rpg_characters ch ON ch.id = p.character_id
               LEFT JOIN public.rpg_creatures cr ON cr.id = p.creature_id
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id
                AND (v_gm OR p.creature_id IS NULL
                     OR EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                 WHERE o.session_id = s.id AND o.creature_id IS NULL AND o.pos_x IS NOT NULL AND p.pos_x IS NOT NULL
                                   AND public.rpg_square_gap(o.pos_x, o.pos_y, p.pos_x, p.pos_y) <= public.rpg_setting('sight_squares')))), '[]'::jsonb),
           'can_join', CASE WHEN NOT v_gm THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb) END)
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', v_l.name, 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_l.cols, 'rows', v_l.rows, 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

REVOKE ALL ON FUNCTION public.rpg_map_grown(integer, integer, integer, double precision) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_layers() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_rolls(integer, integer, integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_within(uuid, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_grown(integer, integer, integer, double precision) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_layers() TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_rolls(integer, integer, integer, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_within(uuid, integer, integer, integer, integer, integer) TO service_role;

UPDATE public.rpg_rules
   SET body = replace(body, 'The rest stays blank until someone goes there or knows the place.', 'The rest stays dark until someone goes there or knows the place.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map';

