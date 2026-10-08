-- Roleplaying world map, lake beds on fine grids (step 14f-battle). A lake's shore and bed were read on the heights of the grid
-- shown, so on the battle grid the land's smallest rises broke a pond's bed into deep and shallow squares at random and
-- left wet and dry squares scattered along its shore. rpg_map_flow now reads a lake's shore and bed on the heights of the
-- grid one finer than the lake's own (or the grid shown, when that is coarser), blended across that grid's cells, so the
-- shore is one clean line and the bed falls smoothly from it.

CREATE OR REPLACE FUNCTION public.rpg_map_flow(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, depth double precision, line integer, current double precision, marsh boolean)
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
-- ^ 2/3, Manning). Lakes sit in the hollows of the land (step 14f4): the great lakes in the deep hollows of the
-- Continent grid, the big lakes, lakes and ponds in the hollows rpg_map_drain_cell finds on the Country, Region and City
-- grids (map_lake_<grid>_hollow deep, so about 1.5, 1.2 and 1 in 100 of the land is under them, 3.7 in all, as on
-- Earth: Verpoorter et al. 2014), each filled to the height its water spills over at; their
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
-- marsh = dry land in a marsh (step 14f4): below the level of a hollow too shallow to hold a lake (rpg_map_drain_cell),
-- laid by the same shore rule; rpg_map_cells_make makes it swamp.
-- A ford (step 11, Peter 2026-10-04: bridges and fords): on the battle grid, the squares of a river or a stream that
-- rpg_map_ford_cells names (a road that fords it, or a planned ford off the roads) are knee-deep, map_wade_ford_depth
-- (0.5 m) at most, however deep the river is beside them, so the walk wades there instead of swimming; the current
-- follows the shallower depth. A bridge changes no water: its squares are road ground (rpg_map_cells).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     rk AS MATERIALIZED (
       SELECT q.k, (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_depth')::double precision AS deep,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_current')::double precision AS flow
         FROM generate_series(2, 5) AS q(k)),
     rv0 AS MATERIALIZED (
       SELECT r.x, r.y, r.k,
              CASE WHEN r.dist < w.width / 2 AND w.width >= lad.cell THEN w.deep * (1 - power(2 * r.dist / w.width, 2)) ELSE 0 END AS depth,
              CASE WHEN r.inside THEN r.k END AS line, w.deep, w.flow
         FROM public.rpg_map_rivers(p_level, p_x0, p_y0, p_cols, p_rows) r CROSS JOIN lad
         -- (step 14e) each size's width, depth and current read once, not once a square (the same numbers, about five
         -- times faster on a block with a river)
         LEFT JOIN rk w ON w.k = r.k),
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
     -- the lakes (steps 14f1 and 14f4): the great lakes, the deep hollows of the Continent grid (rpg_map_drainage), and
     -- the big lakes, lakes and ponds in the hollows found inside each cell of the Country, Region and City grids'
     -- cells above (rpg_map_drain_cell), each full to its rim and each shown from its own grid down. Water lies where
     -- the ground of this grid is below the lake's level, in the lake's own cells and in the near half of the cells of
     -- its rim (so the shore follows the land, not the edges of the lake's cells); the bed drops map_lake_slope from
     -- the shore, down to map_lake_<grid>_depth
     gc AS (SELECT l.level AS lv, l.cell::double precision AS cc, l.across AS cw, l.down AS ch,
                   (SELECT st.value FROM st WHERE st.key = 'map_lake_' || l.level || '_depth')::double precision AS deep
              FROM public.rpg_map_ladder() l WHERE l.level BETWEEN 2 AND least(p_level, 5)),
     -- the cells of the grid above each lake size's grid that lie under the block or one of that grid's cells round it
     gp AS (SELECT gc.lv, ((px.x % (gc.cw / 12)) + gc.cw / 12) % (gc.cw / 12) AS px, py.y AS py
              FROM gc CROSS JOIN lad
             CROSS JOIN LATERAL generate_series(floor((p_x0 * lad.cell - gc.cc) / (12 * gc.cc))::integer, floor(((p_x0 + p_cols) * lad.cell + gc.cc) / (12 * gc.cc))::integer) AS px(x)
             CROSS JOIN LATERAL generate_series(greatest(floor((p_y0 * lad.cell - gc.cc) / (12 * gc.cc))::integer, 0),
                                                least(floor(((p_y0 + p_rows) * lad.cell + gc.cc) / (12 * gc.cc))::integer, gc.ch / 12 - 1)) AS py(y)
             WHERE gc.lv >= 3),
     gk AS MATERIALIZED (
       SELECT 2 AS lv, (e.v ->> 0)::double precision AS lvl, (c.v ->> 0)::integer AS cx, (c.v ->> 1)::integer AS cy, false AS marsh
         FROM jsonb_array_elements(public.rpg_map_drainage() -> 'lakes') WITH ORDINALITY AS e(v, n)
        CROSS JOIN LATERAL jsonb_array_elements(e.v) WITH ORDINALITY AS c(v, i)
        WHERE c.i > 1 AND p_level >= 2
       UNION ALL
       -- (and the marshes, step 14f4: the shallower hollows, wet ground rather than open water)
       SELECT gp.lv, (e.v ->> 0)::double precision, gp.px * 12 + (c.v::text::integer % 12), gp.py * 12 + (c.v::text::integer / 12), w.m
         FROM (SELECT DISTINCT gp.lv, gp.px, gp.py FROM gp) gp
        CROSS JOIN LATERAL (SELECT public.rpg_map_drain_cell(gp.lv, gp.px, gp.py) AS j) dj
        CROSS JOIN (VALUES ('l', false), ('m', true)) AS w(k, m)
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(dj.j -> w.k, '[]'::jsonb)) AS e(v)
        CROSS JOIN LATERAL jsonb_array_elements(e.v) WITH ORDINALITY AS c(v, i)
        WHERE c.i > 1),
     gb AS MATERIALIZED (
       -- the block's cells that lie in a lake's cell or one beside it, with that cell and where in it the cell lies
       SELECT DISTINCT u.lv, b.x, b.y, q.cx, q.cy, q.fx, q.fy
         FROM lad
        CROSS JOIN LATERAL (SELECT DISTINCT gk.lv, gk.cx + ox.o AS ux, gk.cy + oy.o AS uy
                              FROM gk CROSS JOIN (VALUES (-1), (0), (1)) AS ox(o) CROSS JOIN (VALUES (-1), (0), (1)) AS oy(o)) u
         JOIN gc ON gc.lv = u.lv
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
       -- each such cell's lake of each size: its own cell's, else the lake of a rim cell it lies in the near half of (a
       -- lake before a marsh)
       SELECT DISTINCT ON (gb.lv, gb.x, gb.y) gb.lv, gb.x, gb.y, gk.lvl, gc.deep, gk.marsh
         FROM gb JOIN gc ON gc.lv = gb.lv
         JOIN gk ON gk.lv = gb.lv AND abs(public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw)) <= 1 AND abs(gk.cy - gb.cy) <= 1
        CROSS JOIN LATERAL (SELECT public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw) AS dx, gk.cy - gb.cy AS dy) d
        WHERE (d.dx = 0 AND d.dy = 0)
           OR ((d.dx = 0 OR (d.dx = 1 AND gb.fx >= 0.5) OR (d.dx = -1 AND gb.fx < 0.5))
               AND (d.dy = 0 OR (d.dy = 1 AND gb.fy >= 0.5) OR (d.dy = -1 AND gb.fy < 0.5)))
        ORDER BY gb.lv, gb.x, gb.y, (d.dx = 0 AND d.dy = 0) DESC, gk.marsh, gk.lvl DESC),
     -- (step 14f-battle) a lake's shore and bed are read on the heights of the grid one finer than its own, or this grid
     -- when that is coarser, blended across that grid's cells: on a much finer grid the land's smallest rises would
     -- break a pond's bed into deep and shallow squares at random, so the bed falls smoothly from the shore instead
     gm AS MATERIALIZED (
       SELECT DISTINCT least(p_level, gw.lv + 1) AS m, l.cell::double precision AS mc
         FROM gw JOIN public.rpg_map_ladder() l ON l.level = least(p_level, gw.lv + 1)),
     gh AS MATERIALIZED (
       SELECT gm.m, h.x, h.y, h.height
         FROM gm CROSS JOIN lad
        CROSS JOIN LATERAL (SELECT floor((p_x0 + 0.5) * lad.cell / gm.mc - 0.5)::integer - 1 AS x0, floor((p_y0 + 0.5) * lad.cell / gm.mc - 0.5)::integer - 1 AS y0,
                                   floor((p_x0 + p_cols - 0.5) * lad.cell / gm.mc - 0.5)::integer + 2 AS x1, floor((p_y0 + p_rows - 0.5) * lad.cell / gm.mc - 0.5)::integer + 2 AS y1) r
        CROSS JOIN LATERAL public.rpg_map_heights(gm.m, r.x0, r.y0, r.x1 - r.x0 + 1, r.y1 - r.y0 + 1) h),
     gi AS (
       -- each lake cell's ground and slope there (height per square), blended from the four cells of that grid round it
       SELECT gw.x, gw.y, gw.marsh, gw.lvl, gw.deep,
              (1 - q.fv) * ((1 - q.fu) * a.height + q.fu * b.height) + q.fv * ((1 - q.fu) * c.height + q.fu * d.height) AS h,
              sqrt(power((1 - q.fv) * (b.height - a.height) + q.fv * (d.height - c.height), 2)
                   + power((1 - q.fu) * (c.height - a.height) + q.fu * (d.height - b.height), 2)) / gm.mc AS grad
         FROM gw CROSS JOIN lad
         JOIN gm ON gm.m = least(p_level, gw.lv + 1)
        CROSS JOIN LATERAL (SELECT (gw.x + 0.5) * lad.cell / gm.mc - 0.5 AS u, (gw.y + 0.5) * lad.cell / gm.mc - 0.5 AS v) uv
        CROSS JOIN LATERAL (SELECT floor(uv.u)::integer AS i, floor(uv.v)::integer AS j, uv.u - floor(uv.u) AS fu, uv.v - floor(uv.v) AS fv) q
         JOIN gh a ON a.m = gm.m AND a.x = q.i AND a.y = q.j
         JOIN gh b ON b.m = gm.m AND b.x = q.i + 1 AND b.y = q.j
         JOIN gh c ON c.m = gm.m AND c.x = q.i AND c.y = q.j + 1
         JOIN gh d ON d.m = gm.m AND d.x = q.i + 1 AND d.y = q.j + 1),
     gl AS (
       SELECT gi.x, gi.y, gi.marsh,
              CASE WHEN gi.marsh THEN 0 ELSE 1 END * least(gi.deep,
                    (gi.lvl - gi.h) / greatest(gi.grad, 1e-12)
                    * (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision
                    * (SELECT st.value FROM st WHERE st.key = 'map_lake_slope')::double precision) AS depth
         FROM gi
        -- (the lake's own level less the 0.001 a hollow must be filled by to count as one, as rpg_map_drain_make: the
        -- cell its water spills over stands at the lake's level and is its shore)
        WHERE gi.h < gi.lvl - 1e-3),
     dep AS (SELECT rv.x, rv.y, rv.depth, rv.line, rv.current, false AS marsh FROM rv
             UNION ALL
             SELECT gl.x, gl.y, gl.depth, NULL::integer,
                    CASE WHEN gl.marsh THEN 0 ELSE (SELECT st.value FROM st WHERE st.key = 'map_still_current')::double precision END, gl.marsh FROM gl
)
SELECT b.x, b.y, coalesce(max(dep.depth), 0), coalesce(min(dep.line), 0), coalesce(max(dep.current), 0),
       coalesce(bool_or(dep.marsh), false) AND coalesce(max(dep.depth), 0) = 0
  FROM (SELECT gx AS x, gy AS y FROM generate_series(p_x0, p_x0 + p_cols - 1) gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) gy) b
  LEFT JOIN dep ON dep.x = b.x AND dep.y = b.y
 GROUP BY b.x, b.y;
$function$;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

