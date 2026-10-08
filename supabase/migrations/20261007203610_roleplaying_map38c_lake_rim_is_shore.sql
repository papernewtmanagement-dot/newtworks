-- Step 14f1 follow-up: the Continent cell a great lake spills over stands at the lake's own level (less a millionth);
-- it was counted as water a hundredth of a millimetre deep, which made the World map read the depth of every Continent
-- cell (2 s). It is the lake's shore now, as the routing treats it.
CREATE OR REPLACE FUNCTION public.rpg_map_flow(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, depth double precision, line integer, current double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rivers and lakes on any block of any grid, worked out when asked and never stored: the one home of where water lies
-- on land and how it flows (Peter 2026-10-03 17:28: rivers and lakes; step 7b: swimming). rpg_map_water reads it for
-- depth and line, rpg_map_swim for the pull a swimmer meets.
-- Rivers run where rpg_map_rivers says, with their bends: great rivers 400 m wide (Continent), rivers 60 m (Country),
-- streams 10 m (Region), brooks 2 m (City), each map_river_<grid>_width squares wide and map_river_<grid>_depth deep in
-- the middle, shallower toward the banks (depth = middle x (1 - (2 x distance / width)^2)), and flowing
-- map_river_<grid>_current m/s in the middle, slower where it is shallower (speed = middle x (depth / middle depth)
-- ^ 2/3, Manning). Lakes sit where a field of a grid's rolls (part 8) rises above the height that leaves
-- map_lake_<grid>_share of the land under water (big lakes, lakes, ponds: 1.5, 1.2 and 1 in 100, 3.7 in all); their
-- bed drops map_lake_slope (1 in 20) from the shore, down to map_lake_<grid>_depth; their water is still
-- (map_still_current, 0.1 m/s of small waves). A grid shows only the water its own cells or coarser ones make: a brook
-- is not on the Region grid. depth = metres of water at the middle of the cell (the deepest of what lies there; 0 for
-- none). A river narrower than the grid's cell is a line on that grid and not water in the cell (step 10a, 2026-10-05:
-- before, a 60 m river crossing the middle of a 1.2-mile cell made the whole cell water, a chain of ponds along the
-- line once the line wandered); it fills cells only on grids whose cells it is at least as wide as (a great river
-- from the City grid down, a river and a stream on the District grid and the battle grid, a brook on the battle
-- grid). line = the biggest river whose line runs through the cell (2 a great river, 3 a river, 4 a stream, 5 a
-- brook; 0 none): a grid too coarse to hold a river as cells still knows it is there (rpg_map_walk looks closer at a
-- deep one). current = how fast the water there pulls, m/s (the fastest of what lies there; 0 on dry land).
-- A ford (step 11, Peter 2026-10-04: bridges and fords): on the battle grid, the squares of a river or a stream that
-- rpg_map_ford_cells names (a road that fords it, or a planned ford off the roads) are knee-deep, map_wade_ford_depth
-- (0.5 m) at most, however deep the river is beside them, so the walk wades there instead of swimming; the current
-- follows the shallower depth. A bridge changes no water: its squares are road ground (rpg_map_cells).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the spread of a field read from three layers counting 1, 1 and 0.6 (see rpg_map_hard for the sum)
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0) * 2.36) AS s),
     rv0 AS MATERIALIZED (
       SELECT r.x, r.y, r.k,
              CASE WHEN r.dist < w.width / 2 AND w.width >= lad.cell THEN w.deep * (1 - power(2 * r.dist / w.width, 2)) ELSE 0 END AS depth,
              CASE WHEN r.inside THEN r.k END AS line, w.deep, w.flow
         FROM public.rpg_map_rivers(p_level, p_x0, p_y0, p_cols, p_rows) r CROSS JOIN lad
        CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_width')::double precision AS width,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_depth')::double precision AS deep,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_current')::double precision AS flow) w),
     -- the fords of the block (step 11): only the battle grid, only where it holds a river or a stream
     fd AS MATERIALIZED (
       SELECT f.x, f.y, f.k, (SELECT st.value FROM st WHERE st.key = 'map_wade_ford_depth')::double precision AS deep
         FROM public.rpg_map_ford_cells(p_level, p_x0, p_y0, p_cols, p_rows) f
        WHERE p_level = 7 AND EXISTS (SELECT 1 FROM rv0 WHERE rv0.k IN (3, 4) AND rv0.depth > 0)),
     rv AS (SELECT rv0.x, rv0.y, q.depth, rv0.line,
                   CASE WHEN q.depth > 0 THEN rv0.flow * power(q.depth / rv0.deep, 2.0 / 3) ELSE 0 END AS current
              FROM rv0
              LEFT JOIN fd ON fd.x = rv0.x AND fd.y = rv0.y AND fd.k = rv0.k
             CROSS JOIN LATERAL (SELECT CASE WHEN fd.x IS NOT NULL THEN least(rv0.depth, fd.deep) ELSE rv0.depth END AS depth) q),
     cls AS MATERIALIZED (
       SELECT q.k, k.cell::double precision AS kcell,
              (SELECT st.value FROM st WHERE st.key = 'map_lake_' || q.k || '_share')::double precision AS a,
              (SELECT st.value FROM st WHERE st.key = 'map_lake_' || q.k || '_depth')::double precision AS deep
         FROM generate_series(3, 5) AS q(k)
         JOIN public.rpg_map_ladder() k ON k.level = q.k
        WHERE q.k <= p_level),
     f AS MATERIALIZED (
       -- each lake field on the block and one cell round it
       SELECT c.k, r.x, r.y, r.value
         FROM cls c CROSS JOIN LATERAL public.rpg_map_rolls(8, 3 * c.k - 2, c.kcell::integer, p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) r),
     nb AS (
       SELECT f.k, f.x, f.y, f.value AS v,
              lead(f.value) OVER (PARTITION BY f.k, f.y ORDER BY f.x) AS e, lag(f.value) OVER (PARTITION BY f.k, f.y ORDER BY f.x) AS w,
              lead(f.value) OVER (PARTITION BY f.k, f.x ORDER BY f.y) AS s, lag(f.value) OVER (PARTITION BY f.k, f.x ORDER BY f.y) AS n
         FROM f),
     lk AS (
       -- squares in from the shore (the roll past the lake's height over how fast it changes), then the depth there
       SELECT nb.x, nb.y,
              least(c.deep, greatest((nb.v - z.t) / greatest(sqrt(power((nb.e - nb.w) / 2, 2) + power((nb.s - nb.n) / 2, 2)), 1e-9) * lad.cell, 0)
                            * (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision
                            * (SELECT st.value FROM st WHERE st.key = 'map_lake_slope')::double precision) AS depth
         FROM nb JOIN cls c ON c.k = nb.k CROSS JOIN lad CROSS JOIN sd
        -- the height that leaves the lake's share above it, by the normal curve (Abramowitz and Stegun 26.2.23)
        CROSS JOIN LATERAL (SELECT sd.s * (sqrt(-2 * ln(c.a)) - (2.515517 + 0.802853 * sqrt(-2 * ln(c.a)) + 0.010328 * (-2 * ln(c.a)))
                                           / (1 + 1.432788 * sqrt(-2 * ln(c.a)) + 0.189269 * (-2 * ln(c.a)) + 0.001308 * power(sqrt(-2 * ln(c.a)), 3))) AS t) z
        WHERE nb.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND nb.y BETWEEN p_y0 AND p_y0 + p_rows - 1),
     -- the great lakes (step 14f1): the deep hollows of the Continent grid (rpg_map_drainage), full to their rim. Water
     -- lies where the ground of this grid is below the lake's level, in the lake's own Continent cells and in the near
     -- half of the cells of its rim (so the shore follows the land, not the edges of the Continent cells); the bed drops
     -- map_lake_slope from the shore, down to map_lake_2_depth
     gc AS (SELECT l.cell::double precision AS cc, l.across AS cw FROM public.rpg_map_ladder() l WHERE l.level = 2),
     gk AS MATERIALIZED (
       SELECT (e.v ->> 0)::double precision AS lvl, (c.v ->> 0)::integer AS cx, (c.v ->> 1)::integer AS cy, e.n AS lake
         FROM jsonb_array_elements(public.rpg_map_drainage() -> 'lakes') WITH ORDINALITY AS e(v, n)
        CROSS JOIN LATERAL jsonb_array_elements(e.v) WITH ORDINALITY AS c(v, i)
        WHERE c.i > 1 AND p_level >= 2),
     gb AS MATERIALIZED (
       -- the block's cells that lie in a great lake's Continent cell or one beside it, with that Continent cell and where
       -- in it the cell lies
       SELECT DISTINCT b.x, b.y, q.cx, q.cy, q.fx, q.fy
         FROM lad CROSS JOIN gc
        CROSS JOIN LATERAL (SELECT DISTINCT gk.cx + ox.o AS ux, gk.cy + oy.o AS uy
                              FROM gk CROSS JOIN (VALUES (-1), (0), (1)) AS ox(o) CROSS JOIN (VALUES (-1), (0), (1)) AS oy(o)) u
        CROSS JOIN LATERAL (SELECT k.k FROM generate_series(floor((p_x0 * lad.cell - u.ux * gc.cc) / (gc.cw * gc.cc))::integer,
                                                              floor(((p_x0 + p_cols) * lad.cell - u.ux * gc.cc) / (gc.cw * gc.cc))::integer) AS k(k)) w
        CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(((u.ux + w.k * gc.cw) * gc.cc) / lad.cell)::integer),
                                           least(p_x0 + p_cols - 1, ceil(((u.ux + w.k * gc.cw + 1) * gc.cc) / lad.cell)::integer - 1)) AS bx(x)
        CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((u.uy * gc.cc) / lad.cell)::integer),
                                           least(p_y0 + p_rows - 1, ceil(((u.uy + 1) * gc.cc) / lad.cell)::integer - 1)) AS byy(y)
        CROSS JOIN LATERAL (SELECT bx.x, byy.y) b
        CROSS JOIN LATERAL (SELECT (mod(mod(floor((b.x + 0.5) * lad.cell / gc.cc)::bigint, gc.cw) + gc.cw, gc.cw))::integer AS cx,
                                   floor((b.y + 0.5) * lad.cell / gc.cc)::integer AS cy,
                                   (b.x + 0.5) * lad.cell / gc.cc - floor((b.x + 0.5) * lad.cell / gc.cc) AS fx,
                                   (b.y + 0.5) * lad.cell / gc.cc - floor((b.y + 0.5) * lad.cell / gc.cc) AS fy) q),
     gw AS MATERIALIZED (
       -- each such cell's lake: its own Continent cell's, else the lake of a rim cell it lies in the near half of
       SELECT DISTINCT ON (gb.x, gb.y) gb.x, gb.y, gk.lvl
         FROM gb CROSS JOIN gc
         JOIN gk ON abs(public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw)) <= 1 AND abs(gk.cy - gb.cy) <= 1
        CROSS JOIN LATERAL (SELECT public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw) AS dx, gk.cy - gb.cy AS dy) d
        WHERE (d.dx = 0 AND d.dy = 0)
           OR ((d.dx = 0 OR (d.dx = 1 AND gb.fx >= 0.5) OR (d.dx = -1 AND gb.fx < 0.5))
               AND (d.dy = 0 OR (d.dy = 1 AND gb.fy >= 0.5) OR (d.dy = -1 AND gb.fy < 0.5)))
        ORDER BY gb.x, gb.y, (d.dx = 0 AND d.dy = 0) DESC, gk.lvl DESC),
     gh AS MATERIALIZED (
       SELECT h.x, h.y, h.height FROM public.rpg_map_heights(p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) h WHERE EXISTS (SELECT 1 FROM gw)),
     gl AS (
       SELECT gw.x, gw.y,
              least((SELECT st.value FROM st WHERE st.key = 'map_lake_2_depth')::double precision,
                    (gw.lvl - h.height) / greatest(sqrt(power((e.height - w.height) / 2, 2) + power((s.height - n.height) / 2, 2)), 1e-9) * lad.cell
                    * (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision
                    * (SELECT st.value FROM st WHERE st.key = 'map_lake_slope')::double precision) AS depth
         FROM gw CROSS JOIN lad
         JOIN gh h ON h.x = gw.x AND h.y = gw.y
         JOIN gh e ON e.x = gw.x + 1 AND e.y = gw.y JOIN gh w ON w.x = gw.x - 1 AND w.y = gw.y
         JOIN gh s ON s.x = gw.x AND s.y = gw.y + 1 JOIN gh n ON n.x = gw.x AND n.y = gw.y - 1
        -- (the lake's own level less the 0.001 a hollow must be filled by to count as one, as rpg_map_drain_make: the
        -- cell its water spills over stands at the lake's level and is its shore)
        WHERE h.height < gw.lvl - 1e-3),
     dep AS (SELECT rv.x, rv.y, rv.depth, rv.line, rv.current FROM rv
             UNION ALL
             SELECT gl.x, gl.y, gl.depth, NULL::integer, (SELECT st.value FROM st WHERE st.key = 'map_still_current')::double precision FROM gl
             UNION ALL
             SELECT lk.x, lk.y, lk.depth, NULL::integer,
                    CASE WHEN lk.depth > 0 THEN (SELECT st.value FROM st WHERE st.key = 'map_still_current')::double precision ELSE 0 END
               FROM lk)
SELECT b.x, b.y, coalesce(max(dep.depth), 0), coalesce(min(dep.line), 0), coalesce(max(dep.current), 0)
  FROM (SELECT gx AS x, gy AS y FROM generate_series(p_x0, p_x0 + p_cols - 1) gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) gy) b
  LEFT JOIN dep ON dep.x = b.x AND dep.y = b.y
 GROUP BY b.x, b.y;
$function$;

SELECT public.rpg_map_cache_clear();

