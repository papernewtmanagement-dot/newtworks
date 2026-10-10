ALTER TABLE public.rpg_settings DISABLE TRIGGER rpg_settings_map_cache;
INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
('126794dd-25ff-47d2-a436-724499733365', 'map_rapids_hills', 1.5, 'Rapids: a river over hills pulls this many times as fast (a steeper bed runs faster, Manning)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_rapids_mountains', 2, 'Rapids: a river over mountains pulls this many times as fast (mountain rivers run 2 to 3 m/s in steep reaches)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_falls_current', 3, 'Waterfall: m/s a river pulls where it runs over a mountain cliff (too rough to swim)')
ON CONFLICT (agency_id, key) DO NOTHING;
ALTER TABLE public.rpg_settings ENABLE TRIGGER rpg_settings_map_cache;
-- the three new settings feed no saved map (rapids are read live), so the saved map's fingerprint is brought up to date instead of forgetting it
UPDATE public.rpg_map_cache m SET notes = jsonb_set(m.notes, '{fp,all}', to_jsonb((SELECT md5(coalesce(string_agg(s.key || '=' || s.value, ';' ORDER BY s.key) FILTER (WHERE s.key NOT LIKE 'map\_road\_%'), '')) FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key LIKE 'map\_%')))
 WHERE m.level = -1 AND m.gx = 0 AND m.gy = 0 AND m.notes -> 'fp' ->> 'all' = (SELECT md5(coalesce(string_agg(s.key || '=' || s.value, ';' ORDER BY s.key) FILTER (WHERE s.key NOT LIKE 'map\_road\_%' AND s.key NOT IN ('map_rapids_hills', 'map_rapids_mountains', 'map_falls_current')), '')) FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key LIKE 'map\_%');
CREATE OR REPLACE FUNCTION public.rpg_map_mountain_cliffs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, angle double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid steep enough to be a cliff if they are mountains, and how steep (step 7c;
-- moved out of rpg_map_cliffs, more terrain step 2a, 2026-10-10, so the waterfalls read the same squares): a square
-- whose steep (rpg_map_steep) is in the top map_cliff_share (1 in 20), at its own angle (rpg_map_cliff_angle). Only the
-- battle grid; the ground is the caller's to check (rpg_map_cliffs: a mountain cliff; rpg_map_rush: a waterfall where a
-- river runs over one).
SELECT s.x, s.y, a.angle FROM public.rpg_map_steep(p_level, p_x0, p_y0, p_cols, p_rows) s
 CROSS JOIN LATERAL (SELECT public.rpg_map_cliff_angle(s.steep) AS angle) a
 WHERE p_level = 7 AND s.steep >= 1 - (SELECT st2.value FROM public.rpg_settings st2
                                       WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_cliff_share')
   AND a.angle IS NOT NULL;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_cliffs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, mountains double precision, hills double precision, gorge integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cliffs of a block of the battle grid, worked out when asked and never stored: the one home of which squares are
-- rock to climb and how steep (rpg_map_cliff, rpg_map_costs, rpg_map_walk and rpg_map_view_block read it, each with the
-- square's own ground: mountains = how steep the square is when it is mountains, hills = when it is hills; any other
-- ground has no cliffs).
-- Two kinds of cliff (step 7c; canyons, Peter 2026-10-09: when rivers run through hills or mountains that would create
-- canyons):
--  * a mountain square whose steep (rpg_map_steep) is in the top map_cliff_share, at its own angle (rpg_map_cliff_angle);
--  * the wall of a gorge: a hills or mountains square beside a river (rpg_map_river_line: great rivers, rivers and
--    streams; a brook cuts no gorge), out to the rim. The gorge is map_gorge_depth_K metres deep in hills (great river 40,
--    river 25, stream 8) and map_gorge_mountain_times (3) that in mountains (120, 75, 24); its walls stand at
--    map_gorge_angle_hills (55 degrees) or map_gorge_angle_mountains (70), so each wall reaches depth / tan(angle) past
--    the bank (half the river wide from its middle line): a river in hills 25 m / tan 55 = 17.5 m, 16 squares each side;
--    in mountains 75 m / tan 70 = 27.3 m, 24 squares.
-- Where both meet the steeper wins. gorge = the size of river whose gorge wall the square is (2 great river, 3 river,
-- 4 stream; nothing when it is no gorge wall). Only the battle grid has cliffs: a coarser grid's cells are walked at
-- their ground's own time. Squares with no cliff on either ground have no row.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
               AND (s.key LIKE 'map\_gorge\_%' OR s.key LIKE 'map\_river\__\_width' OR s.key = 'map_square_m')),
     cf AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_hills')::double precision AS ah,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_mountains')::double precision AS am,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_mountain_times')::double precision AS times,
                   (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq),
     -- each size of river and ground: half the river wide, how deep its gorge, how steep and how far past the bank its
     -- wall reaches, in squares
     kw AS (SELECT w.k, g.kind, (SELECT st.value FROM st WHERE st.key = 'map_river_' || w.k || '_width')::double precision / 2 AS half,
                   d.depth, a.angle, d.depth / tan(radians(a.angle)) / cf.sq AS wall
              FROM generate_series(2, 5) AS w(k) CROSS JOIN cf
             CROSS JOIN (VALUES ('hills'), ('mountains')) AS g(kind)
             CROSS JOIN LATERAL (SELECT coalesce((SELECT st.value FROM st WHERE st.key = 'map_gorge_depth_' || w.k)::double precision, 0)
                                        * CASE WHEN g.kind = 'mountains' THEN cf.times ELSE 1 END AS depth) d
             CROSS JOIN LATERAL (SELECT CASE WHEN g.kind = 'mountains' THEN cf.am ELSE cf.ah END AS angle) a
             WHERE d.depth > 0 AND p_level = 7),
     kr AS (SELECT kw.k, max(kw.half + kw.wall) AS reach FROM kw GROUP BY kw.k),
     -- the rivers that cut gorges (great rivers, rivers, streams) near the block, as pieces between their points, each
     -- kept when it comes within its own gorge's reach of the block
     -- the rivers that cut gorges (great rivers, rivers, streams; read with the brooks, as the rivers are drawn, and the
     -- brooks left out by their gorge depth of 0) near the block, as straight pieces between every
     -- fourth point of their line (a square apart on the battle grid; four squares strays from the line by well under a
     -- square, nothing beside a wall tens of squares wide), each kept when it comes within its own gorge's reach of the block
     pt AS (SELECT r.pid, r.k, r.t, r.x, r.y, row_number() OVER (PARTITION BY r.pid ORDER BY r.t) AS rn, count(*) OVER (PARTITION BY r.pid) AS n
              FROM (SELECT max(kr.reach) + 1 AS reach FROM kr HAVING count(*) > 0) m
             CROSS JOIN LATERAL public.rpg_map_river_line(7, 1, p_x0::double precision, p_y0::double precision,
                                                          (p_x0 + p_cols)::double precision, (p_y0 + p_rows)::double precision,
                                                          greatest(m.reach, 180)) r),
     rl AS MATERIALIZED (
       SELECT q.* FROM (
         SELECT pt.k, pt.x AS x0, pt.y AS y0, lead(pt.x) OVER w AS x1, lead(pt.y) OVER w AS y1
           FROM pt WHERE mod(pt.rn - 1, 4) = 0 OR pt.rn = pt.n
         WINDOW w AS (PARTITION BY pt.pid ORDER BY pt.t)) q
        JOIN kr ON kr.k = q.k
        WHERE q.x1 IS NOT NULL
          AND greatest(q.x0, q.x1) >= p_x0 - kr.reach AND least(q.x0, q.x1) <= p_x0 + p_cols + kr.reach
          AND greatest(q.y0, q.y1) >= p_y0 - kr.reach AND least(q.y0, q.y1) <= p_y0 + p_rows + kr.reach),
     sq AS (SELECT gx.x, gy.y FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy(y)
             WHERE EXISTS (SELECT 1 FROM rl)),
     -- each square and how near each size of river comes to its middle
     nd AS (SELECT sq.x, sq.y, rl.k, min(n.d) AS d
              FROM sq JOIN kr ON true
              JOIN rl ON rl.k = kr.k
                     AND sq.x + 0.5 BETWEEN least(rl.x0, rl.x1) - kr.reach AND greatest(rl.x0, rl.x1) + kr.reach
                     AND sq.y + 0.5 BETWEEN least(rl.y0, rl.y1) - kr.reach AND greatest(rl.y0, rl.y1) + kr.reach
             CROSS JOIN LATERAL public.rpg_seg_nearest(sq.x + 0.5, sq.y + 0.5, rl.x0, rl.y0, rl.x1, rl.y1) n
             GROUP BY sq.x, sq.y, rl.k),
     -- the gorge wall a square is on each ground: the deepest gorge it is inside the rim of (a square under the river is
     -- water, not hills or mountains, so is never climbed)
     gw AS (SELECT nd.x, nd.y, kw.kind, kw.angle, nd.k, kw.depth
              FROM nd JOIN kw ON kw.k = nd.k WHERE nd.d < kw.half + kw.wall),
     gm AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'mountains' ORDER BY gw.x, gw.y, gw.depth DESC),
     gh AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'hills' ORDER BY gw.x, gw.y, gw.depth DESC),
     -- (walk speed step) only the squares steep enough to be a cliff (the top map_cliff_share) are given their angle
     -- (more terrain step 2a: the one home of them is rpg_map_mountain_cliffs, which the waterfalls read too)
     mc AS (SELECT m.x, m.y, m.angle FROM public.rpg_map_mountain_cliffs(p_level, p_x0, p_y0, p_cols, p_rows) m),
     al AS (SELECT gm.x, gm.y FROM gm UNION SELECT gh.x, gh.y FROM gh UNION SELECT mc.x, mc.y FROM mc)
SELECT al.x, al.y, greatest(gm.angle, mc.angle), gh.angle,
       CASE WHEN gm.angle >= coalesce(mc.angle, 0) THEN gm.k ELSE gh.k END
  FROM al LEFT JOIN gm ON gm.x = al.x AND gm.y = al.y LEFT JOIN gh ON gh.x = al.x AND gh.y = al.y
  LEFT JOIN mc ON mc.x = al.x AND mc.y = al.y;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_rush(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, rush text, pull double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rapids and waterfalls (more terrain step 2a, Peter 2026-10-10): how the ground under a river speeds its water, the one
-- home of it, on the battle grid only (the grid swimming is played on). A river runs faster down a steeper bed (Manning:
-- speed grows with the square root of the slope), so where its bed is hills its water pulls map_rapids_hills (1.5)
-- times as fast and where it is mountains map_rapids_mountains (2) times: rapids. Mountain rivers in steep reaches run
-- 2 to 3 m/s against a lowland river's 1 or so. Where a river runs over a mountain square steep enough to be a cliff
-- (rpg_map_mountain_cliffs) it falls: a waterfall, pulling map_falls_current (3 m/s), too rough for any swimmer
-- (map_swim_too_rough, 2.1). rpg_map_flow applies it to river water (not lakes, which are still), rpg_map_view_block
-- draws it. Rows: every hills or mountains square of the block; pull = the times for rapids, nothing for a waterfall.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
             AND s.key IN ('map_rapids_hills', 'map_rapids_mountains')),
     g AS MATERIALIZED (SELECT gr.x, gr.y, gr.kind FROM public.rpg_map_ground_of(p_level, p_x0, p_y0, p_cols, p_rows) gr
                         WHERE p_level = 7 AND gr.kind IN ('hills', 'mountains')),
     mc AS MATERIALIZED (SELECT m.x, m.y FROM public.rpg_map_mountain_cliffs(p_level, p_x0, p_y0, p_cols, p_rows) m
                          WHERE EXISTS (SELECT 1 FROM g WHERE g.kind = 'mountains'))
SELECT g.x, g.y,
       CASE WHEN g.kind = 'mountains' AND mc.x IS NOT NULL THEN 'falls' ELSE 'rapids' END,
       CASE WHEN g.kind = 'mountains' AND mc.x IS NOT NULL THEN NULL
            WHEN g.kind = 'mountains' THEN (SELECT st.value FROM st WHERE st.key = 'map_rapids_mountains')::double precision
            ELSE (SELECT st.value FROM st WHERE st.key = 'map_rapids_hills')::double precision END
  FROM g LEFT JOIN mc ON mc.x = g.x AND mc.y = g.y;
$function$;
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
-- Rapids and waterfalls (more terrain step 2a, 2026-10-10): on the battle grid a river over hills pulls 1.5 times as fast,
-- over mountains twice, and over a mountain cliff it is a waterfall at 3 m/s (rpg_map_rush).
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
     -- (more terrain step 2a) rapids and waterfalls: the battle grid's river water over hills or mountains, only where the
     -- block holds river water (rpg_map_rush)
     ru AS MATERIALIZED (
       SELECT r.x, r.y, r.rush, r.pull FROM public.rpg_map_rush(p_level, p_x0, p_y0, p_cols, p_rows) r
        WHERE p_level = 7 AND EXISTS (SELECT 1 FROM rv0 WHERE rv0.depth > 0)),
     rv AS (SELECT rv0.x, rv0.y, q.depth, rv0.line,
                   CASE WHEN q.depth <= 0 THEN 0
                        -- a waterfall pulls map_falls_current wherever it falls; a ford through it is not made
                        WHEN ru.rush = 'falls' AND fd.x IS NULL THEN (SELECT st.value FROM st WHERE st.key = 'map_falls_current')::double precision
                        ELSE rv0.flow * power(q.depth / rv0.deep, 2.0 / 3) * coalesce(ru.pull, 1) END AS current
              FROM rv0
              LEFT JOIN fd ON fd.x = rv0.x AND fd.y = rv0.y AND fd.k = rv0.k
              LEFT JOIN ru ON ru.x = rv0.x AND ru.y = rv0.y
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
CREATE OR REPLACE FUNCTION public.rpg_map_view_block(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read: one block of cells of one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). The page reads it through rpg_map_view (a whole grid: the world, or the grid inside one
-- cell of the grid above) and rpg_map_place_view (a place shown whole, Peter 2026-10-03). p_level = the grid; p_x0,
-- p_y0 = the first cell of the block, counted across the whole world at that level; p_cols, p_rows = cells across
-- and down, at most one grid's worth; p_place = the place card the block shows whole, nothing for a whole grid. The
-- block of a place may run past the east or west end of the world: those cells are the same ground round the world.
-- Returns the grid (level, name = the kind of grid or the place shown whole, title, view = how the page names it:
-- level-x-y for a whole grid, p-<place id> for a place shown whole, cols, rows, origin = the first cell of the block,
-- scale), the way back up (crumbs; for a place shown whole: the world, the lands that hold its middle, then the
-- place), the grid next door each way (moves, whole grids only), every cell in reading order (x, y, its name like
-- C5, kind sea / land / forest / hills / mountains / place, place = the card it belongs to, marks = other place
-- cards reaching into it, open = the grid inside it), every place card (name, color, icon = the name of its map
-- symbol, size, ground = its ground in words or nothing when it only names the land, the place it is inside, level =
-- the kind of place it is, view = where it opens (rpg_map_place_link), listed = it belongs on this grid's list, spot
-- = where to write its name on this grid: its center from the top-left corner, then its width and height, all four
-- in thousandths of a cell, or nothing when the center is off the grid), list = what this grid lists, the places
-- one level down that reach into it (the world lists continents, a continent countries, a country regions, a region
-- cities, a city districts, a district battle grids; a battle grid lists nothing; a place shown whole lists the
-- places one level down from it whose middle lies inside it), within = the continent, country and so on that hold
-- the middle of this grid (for a place shown whole, the lands above it that hold its middle), biggest first (only
-- places that name the land, the smallest of each kind), grounds = each kind of unnamed ground with its name and
-- its range in words (rpg_map_band_text), and the ladder of grids in words.
-- The world and a place shown whole also carry detail: every cell of the grid one level down inside the block (for
-- the world, the Continent grids: 144 across and 72 down), one character a cell (the letter of its ground in
-- rpg_map_grounds: ~ sea, . open land, t forest and so on; else the character numbered 256 + the place's spot in
-- detail.places, counted from 0), so they
-- are drawn as fine as the grids inside them; wrap = the east edge of the drawing meets its west edge (the world
-- only); marks = the smaller places reaching into a cell of the detail, by its "x,y" counted from 0 at the top-left
-- corner, the same as the marks of a cell.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped; cost = the percent of time a square of it adds to cross it (rpg_map_costs; the average square of
-- its ground on a grid coarser than the City grid); hard = 0 to 9, how far up its ground's range it sits, drawn darker
-- the higher (nothing coarser than the City grid). A grid drawn fine carries hard too, one digit a cell of the detail
-- (- for none). river = the biggest river drawn as a line through a cell too coarse to hold it as water (2 a great
-- river, 3 a river, 4 a stream, 5 a brook; rpg_map_rivers) with the point its line passes nearest the cell's middle,
-- in thousandths of a cell from that middle, so the line is drawn where the river truly runs at every zoom; the detail
-- carries rivers, one digit a cell (0 none), and river_x, river_y, that point as a digit 0 to 9 across the cell.
-- journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join. Under the ground (step
-- 12d2) a piece carries under = where it is in words (rpg_map_under_where); the piece whose turn it is carries ways =
-- its ways on, each [node, words] (rpg_map_under_ways, rpg_map_under_way_words; partway along a passage: on, or back),
-- mouth = it can come up here, search = it can search here for the ways up; on the surface, cave = the name of the cave
-- or mine it stands at and can go into (rpg_map_under_cave_at), or down in a cellar the crack in its floor it can go
-- down through (storeys part 3b, rpg_map_cellar_way); mouth also at the way up into a cellar.
-- towns = the villages, towns and cities the read shows (step 8; rpg_map_towns): the Continent grid its great cities
-- (step 12a), the Country grid its cities and great cities and the Region grid all of them, each a mark in the cell its middle stands in (its id among the marks of that cell); on the City
-- grid and finer the cells of the ground of each (rpg_map_town_cells), which come as kind place with place = its id,
-- so they are drawn and named like a place with ground. A grid drawn fine carries them in its detail the same way.
-- Each is told as rpg_map_town_entry tells it; the Region grid lists its towns, cities and great cities.
-- roads = the roads the read draws (step 8b; rpg_map_roads): highways from the Country grid down, roads and lanes from
-- the Region grid down to the District grid (a place shown whole draws those of the grid of its detail; the battle grid has
-- them as ground of its own, road and mountain road, among its cells). Each piece of road is [size (1 highway, 2 road,
-- 3 lane), x0, y0, x1, y1, x2, y2, ...] in thousandths of a cell from the top-left corner: the points of the wandering
-- line of a stretch (step 10b; rpg_map_road_lines, read at the cell drawn, a point every half cell at least), cut where
-- it leaves the cells that are found and not sea (a road crosses rivers and lakes, by a bridge, a ford or a ferry); the
-- page draws each piece as one smooth line through its points. road_width = how wide each size is, in thousandths of a
-- cell of what is drawn.
-- crossings = where the roads cross the rivers, and the fords off the roads (step 11, Peter 2026-10-04: bridges and
-- fords), from the Region grid down to the District grid, each [kind (1 a bridge, 2 a ford where a road crosses, 3 a
-- planned ford off the roads), river (2 a great river, 3 a river, 4 a stream), road (1 highway, 2 road, 3 lane; 0 for
-- a planned ford), x, y (thousandths of a cell from the top-left corner), angle (degrees, the way across the water,
-- clockwise from east), span (the width of the water there, thousandths of a cell)]: a stretch of road crosses a
-- river by a bridge or a ford as rpg_map_crossing_kind rolls for it, the same at every zoom; a planned ford lies where
-- rpg_map_fords puts it (rivers from the City grid down, streams from the District grid down). The battle grid shows
-- them as ground instead: a cell carries cross = bridge (road ground over water) or ford (knee-deep water a road or a
-- planned ford makes; rpg_map_ford_cells), so the page draws planks or a stony shallow.
-- houses = the houses on the battle grid (step 8c; rpg_map_buildings): each its id, roof (thatch or tile), its middle
-- (x, y in thousandths of a square from the top-left corner), the way its ridge runs ([x, y], thousandths of a step),
-- its length and width (thousandths of a square), its height to the eaves in metres, its roof's pitch in degrees and its
-- storeys. A cell a house stands on carries climb = [wall or roof, metres it climbs, degrees, difficulty of the Climbing
-- roll, what it is in words] (rpg_map_building_cells, rpg_map_climb_words); its cost is the climb's. A landmark stands on
-- the battle grid the same way (step 12b2): each square of its walls, stones or mound carries its climb, part the kind
-- of square (keep, curtain, tower, ruin, stone, boulder, cairn, mound). The kids login sees a house once a cell of it is found.
-- A place to go into stands the same way (step 12c: hut, shrine, cross, outcrop, spoil, palisade, tent), and a square of
-- it walked like the ground carries feature = what it is (floor, hearth, altar, or mouth: the way into a cave or a mine).
-- (step 3) A building is a floor plan on the battle grid (rpg_map_building_squares): its walls and inside walls carry
-- climb (part wall or inner), its doors and floors feature = door, floor (a house or a barn) or flags (a church or the
-- cathedral), walked like the ground. A square of a town or city that a road, its market place, a street or a lane
-- runs over (road ground) carries place = the settlement and paved = 1 (2 the market place), so the page paves it;
-- a village's lanes stay earth. (Storeys step) A house of two storeys or more has its stair (feature stair) on the
-- ground floor, and floors = its upper floors' plans and its cellar's (floor -1), floor by floor, for the Maps tab's floor switch.
-- landmarks = the landmarks the read shows (step 12b; rpg_map_landmarks), from the World grid down to the District grid:
-- each grid those of its own rank and every rank above it, few on the world and more each level down (Peter
-- 2026-10-03 17:28), each a mark in the cell its middle stands in (its id among the marks of that cell; a grid drawn
-- fine carries it in the marks of its detail), told as rpg_map_landmark_entry tells it. The kids login sees a
-- landmark when its cell is found or known, or from as far off as it can be made out (rpg_map_landmark_sight) of where
-- a player character walked, since things seen and steered by from far are what landmarks are (Peter 2026-10-06): a
-- landmark seen that way is marked even in a cell not found yet. The battle grid has none here.
-- under = the world under the ground (step 12d; rpg_map_underground), from the Continent grid down to the District grid:
-- lines = its passages, each [kind (deep, cave, shaft, own, join, delve), from x, y, to x, y (thousandths of a cell from
-- the top-left corner of the block, either end may lie off it), metres down at each end, bend (hundredths of a quarter
-- of its length to one side), how wide at its middle (thousandths of a cell; step 14a), and (step 14a2) where it is
-- wide enough on the map for its bends to show, its path: points along it, each [x, y, half its width] (thousandths of
-- a cell), as rpg_map_under_trace makes them, so the map draws the passage the battle grid cuts (else null: the map
-- draws its curve), and (step 14b) its stream: [share of its width the water covers (thousandths), metres deep at
-- its middle x 10] or null (rpg_map_under_water)]; the Continent and Country grids carry the Deeps alone (step 14a2);
-- rooms (step 14a) = the room at
-- each node a passage reaches, [x, y, half-width, its eight edge knots, its lake (step 14b: [middle off the room's
-- middle across, down (thousandths of its half-width), its size as a share of the room's (thousandths), its eight edge
-- knots, metres deep x 10]) or null], as rpg_map_under_room and rpg_map_under_water make them; halls = the great halls of the Deeps in the block, each [name, x, y, metres down]. The
-- game master sees all of it; the kids login only the own passage of a cave or mine in a cell found or known.
-- On the battle grid (step 12d3) under = the battle grid under the ground instead: squares = every open square under the
-- block (rpg_map_under_squares), each [column, row (from the top-left corner of the block), part (floor, rubble, pool,
-- column, shaft), percent of time it adds (none: no way in), water metres deep, feet down], of the passages and rooms
-- of the Deeps and cave country under the block (rpg_map_underground) and of those round each piece under the ground
-- within 40 squares of it (rpg_map_under_layer: so the passage of a cave or a mine shows where a piece is in it);
-- every other square under it is solid rock. The kids login sees those the group knows, and those round its own pieces.
-- A battle grid may be read slid half a grid at a time (step 14a2; rpg_map_battle_view): view = s-<first square across>-
-- <first square down> then; slides = the grids half a grid west, east, north and south (null off the map).
-- The kids login sees the same read, cut to what the group has found (Peter 2026-10-03, 2A: within sight of where a
-- piece walked, rpg_map_found) or knows (1A: Knowing a place at 1 or more shows all of it, rpg_map_known_places):
-- other cells come as kind unknown with no place, places and lands only once found or known, a place lore only once
-- known, creatures only within sight of a character, and nothing to add.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := 0;
  v_y         integer := 0;
  v_x0        integer := p_x0;
  v_y0        integer := p_y0;
  v_cols      integer := p_cols;
  v_rows      integer := p_rows;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_sub       integer;
  v_dc        integer;
  v_dr        integer;
  v_list_level integer;
  v_pname     text;
  v_pcx       integer;
  v_pcy       integer;
  v_pw        integer;
  v_ph        integer;
  v_plevel    integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_within    jsonb;
  v_grounds   jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_slid      boolean := false;
  v_slides    jsonb;
  v_scale     text;
  v_journey   jsonb;
  v_gm        boolean;
  v_known     uuid[] := '{}';
  v_seen      jsonb := '{}';
  v_towns     jsonb;
  v_dtowns    jsonb;
  v_what      integer;
  v_kinds     jsonb;
  v_dkinds    jsonb;
  v_shown     jsonb;
  v_dshown    jsonb;
  v_roads     jsonb;
  v_rw        jsonb;
  v_houses    jsonb;
  v_hseen     text[];
  v_hlist     jsonb;
  v_hpend     boolean := false;
  v_dcell     jsonb;
  v_rivs      jsonb;
  v_lands     jsonb;
  v_lmk       jsonb;
  v_caves     jsonb;
  v_floors    jsonb;   -- (storeys step) the upper floors of the houses on the battle grid
  v_under     jsonb;
  v_drivs     jsonb;
  v_rsegs     jsonb;   -- step 14c: the traced rivers' pieces near the block, for the crossings
  v_rlines    jsonb;   -- step 14c: the traced rivers' pieces drawn on the grid
  v_cross     jsonb;
  v_rm        integer;
  v_ry0       integer;
  v_ry1       integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_gm := public.family_is_parent();
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_place IS NOT NULL THEN
    SELECT c.name, c.place_x, c.place_y, c.place_w, c.place_h, c.place_level INTO v_pname, v_pcx, v_pcy, v_pw, v_ph, v_plevel
      FROM public.rpg_creatures c
     WHERE c.id = p_place AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'that place is not on the map'; END IF;
  END IF;
  -- a block is 1 to one grid's worth of cells each way (on the world grid 12 by 6), starts no more than its own
  -- width west of the first cell of the world, and stays between the north and south edges
  IF v_x0 IS NULL OR v_y0 IS NULL OR v_cols IS NULL OR v_rows IS NULL
     OR v_cols NOT BETWEEN 1 AND v_l.cols OR v_rows NOT BETWEEN 1 AND v_l.rows
     OR v_x0 NOT BETWEEN 1 - v_cols AND v_l.across - 1 OR v_y0 < 0 OR v_y0 + v_rows > v_l.down THEN
    RAISE EXCEPTION 'that grid is off the map';
  END IF;
  v_list_level := coalesce(v_plevel, v_l.level) + 1;
  IF p_place IS NULL THEN
    -- a whole grid: the world, or the grid inside one cell of the grid above; a battle grid may also be slid half a
    -- grid at a time (step 14a2, Peter 2026-10-07 3A: a passage along its edge comes into the middle), never over the
    -- east or west end of the world; v_x, v_y = the grid it is in (slid half way: the grid east or south)
    IF v_cols <> v_l.cols OR v_rows <> v_l.rows OR v_x0 < 0
       OR (v_l.level < v_last AND (mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0))
       OR (v_l.level = v_last AND (mod(v_x0, v_cols / 2) <> 0 OR mod(v_y0, v_rows / 2) <> 0 OR v_x0 + v_cols > v_l.across)) THEN
      RAISE EXCEPTION 'that grid is off the map';
    END IF;
    v_slid := mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0;
    v_x := (v_x0 + v_cols / 2) / v_cols;
    v_y := (v_y0 + v_rows / 2) / v_rows;
  END IF;
  IF p_place IS NULL AND v_l.level > 1 THEN
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the battle grid slid half a grid each way (step 14a2): a whole grid's name when it lands on one, else s-<x0>-<y0>
  -- (its first square, rpg_map_battle_view)
  IF p_place IS NULL AND v_l.level = v_last THEN
    SELECT jsonb_object_agg(d.k, CASE WHEN d.x < 0 OR d.y < 0 OR d.x + v_cols > v_l.across OR d.y + v_rows > v_l.down THEN NULL
                                      WHEN mod(d.x, v_cols) = 0 AND mod(d.y, v_rows) = 0 THEN v_l.level::text || '-' || (d.x / v_cols)::text || '-' || (d.y / v_rows)::text
                                      ELSE 's-' || d.x::text || '-' || d.y::text END)
      INTO v_slides
      FROM (VALUES ('west', v_x0 - v_cols / 2, v_y0), ('east', v_x0 + v_cols / 2, v_y0),
                   ('north', v_x0, v_y0 - v_rows / 2), ('south', v_x0, v_y0 + v_rows / 2)) AS d(k, x, y);
  END IF;
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_rows)::bigint * v_l.cell;

  IF NOT v_gm THEN
    v_known := public.rpg_map_known_places();
    SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
      FROM public.rpg_map_found(v_l.level, v_x0, v_y0, v_cols, v_rows) f;
  END IF;

  -- the rivers are read a little past the block on the grids that draw crossings (step 11): a bridge over the water
  -- of the District grid may reach three cells in, over the water of the City grid two, a crossing of a line one
  v_rm := CASE WHEN v_l.level = 6 THEN 3 WHEN v_l.level = 5 THEN 2 WHEN v_l.level = 4 THEN 1 ELSE 0 END;
  v_ry0 := greatest(v_y0 - v_rm, 0);
  v_ry1 := least(v_y0 + v_rows + v_rm, v_l.down);
  -- the grids of the block saved the first time they are opened (step 13; rpg_map_cache_fill), so the cells are read
  -- from the saved map from then on
  PERFORM public.rpg_map_cache_fill(v_l.level, v_x0, v_y0, v_cols, v_rows);
  -- (step 3b) a battle grid reads its buildings and street squares from the District grids above it once those are
  -- worked out (rpg_map_district_buildings, saved in the background): each District grid above it already on the saved
  -- map but not worked out yet is asked for here, so the battle grids opened under it next read them
  IF v_l.level = 7 THEN
    PERFORM public.rpg_map_district_buildings((g.gx * g.cols)::integer, (g.gy * g.rows)::integer, g.cols, g.rows)
       FROM (SELECT l.cell::double precision AS c FROM public.rpg_map_ladder() l WHERE l.level = 6) d
      CROSS JOIN LATERAL public.rpg_map_cache_grids(6, floor(v_x0 / d.c)::integer, floor(v_y0 / d.c)::integer,
                                                   (floor((v_x0 + v_cols - 1) / d.c) - floor(v_x0 / d.c) + 1)::integer,
                                                   (floor((v_y0 + v_rows - 1) / d.c) - floor(v_y0 / d.c) + 1)::integer) g
       JOIN public.rpg_map_cache m ON m.level = 6 AND m.gx = g.gx AND m.gy = g.gy
      WHERE NOT coalesce(m.notes ? 'houses', false);
  END IF;
  -- the cells, read once for the villages, towns and cities on them (step 8) and for the picture
  WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows)),
       -- the kinds of the cells of a Continent, Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (2, 3, 4)),
       -- the landmarks of this grid (step 12b): those of its own rank decided by its own cells, those of the ranks above by
       -- the cells of their own grids; none on the battle grid
       lk AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level BETWEEN 2 AND 6),
       lm AS MATERIALIZED (
         SELECT l.*, floor(l.x::double precision / v_l.cell)::integer AS cx, floor(l.y::double precision / v_l.cell)::integer AS cy,
                public.rpg_map_landmark_sight(l.height) AS sight
           FROM public.rpg_map_landmarks(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT lk.k FROM lk)) l
          WHERE v_l.level <= 6 AND l.kind IS NOT NULL),
       -- the cells the known places hold, for the kids login
       kn AS MATERIALIZED (
         SELECT DISTINCT w.x, w.y
           FROM unnest(v_known) AS n(id)
          CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_cols, v_rows) w
          WHERE NOT v_gm),
       -- which landmarks the read shows: all for the game master; for the kids login those in a cell found or known, and
       -- those a player character walked within sight of (the larger of the two gaps, as the game counts distance)
       lv AS MATERIALIZED (
         SELECT lm.*, v_gm OR v_seen ? (lm.cx || ',' || lm.cy) OR EXISTS (SELECT 1 FROM kn WHERE kn.x = lm.cx AND kn.y = lm.cy) AS near FROM lm),
       tr AS MATERIALIZED (SELECT t.* FROM public.rpg_map_trails() t WHERE NOT v_gm AND EXISTS (SELECT 1 FROM lv WHERE NOT lv.near)),
       ls AS MATERIALIZED (
         SELECT lv.*, lv.near OR EXISTS (SELECT 1 FROM tr CROSS JOIN LATERAL (SELECT mod(mod(lv.x, v_world) + v_world, v_world) + 1 AS wx, coalesce(least(lv.sight, tr.sight), lv.sight) AS r) w
                                         WHERE public.rpg_seg_box(tr.x0, tr.y0, tr.x1, tr.y1, w.wx - w.r, lv.y + 1 - w.r, w.wx + w.r, lv.y + 1 + w.r)) AS shown
           FROM lv),
       lmm AS (SELECT ls.cx AS x, ls.cy AS y, jsonb_agg(ls.id ORDER BY ls.id) AS ids FROM ls WHERE ls.shown GROUP BY 1, 2),
       -- the villages, towns and cities marked on this grid (the Continent grid its great cities, the Country grid its
       -- cities and great cities, the Region grid all of them),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT kj.k FROM kj)) t
          WHERE v_l.level IN (2, 3, 4) AND t.kind IS NOT NULL),
       tm AS (SELECT floor(tw.x::double precision / v_l.cell)::integer AS x, floor(tw.y::double precision / v_l.cell)::integer AS y,
                     jsonb_agg(tw.id ORDER BY tw.id) AS ids
                FROM tw GROUP BY 1, 2),
       -- the words for their streets, once
       gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
       -- the City grid and finer: the cells of their ground
       tg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) t WHERE v_l.level >= 5),
       -- the battle grid: the squares a house stands on (step 8c), where a village, town, city or place is
       hb AS MATERIALIZED (SELECT b.* FROM public.rpg_map_building_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) b
                            WHERE v_l.level = 7 AND (EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                                     OR EXISTS (SELECT 1 FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows)))),
       -- the battle grid: the squares of a place to go into walked like the ground (step 12c), one each, and (step 3) the
       -- doors and floors of the buildings, where the block has a building
       -- (storeys step) the floor plans of the buildings, every floor (rpg_map_building_squares), where the block has one
       bsq AS MATERIALIZED (SELECT b.* FROM public.rpg_map_building_squares(v_l.level, v_x0, v_y0, v_cols, v_rows, true) b
                             WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))),
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part, f.house
                             FROM (SELECT f.x, f.y, f.part, NULL::text AS house FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                                    WHERE v_l.level = 7 AND f.angle IS NULL
                                   UNION ALL
                                   SELECT b.x, b.y, b.part, b.id FROM bsq b WHERE b.floor = 0 AND b.angle IS NULL) f
                            ORDER BY f.x, f.y, f.part),
       -- the battle grid: the market place's squares (step 3)
       mk AS MATERIALIZED (SELECT s.x, s.y FROM public.rpg_map_street_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) s
                            WHERE v_l.level = 7 AND s.class = 4 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       -- the rivers near every cell (rpg_map_rivers), read once: for the lines drawn and for the crossings (step 11),
       -- with a margin round the block where a crossing just outside it may still reach in
       rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) r),
       -- the rivers drawn as lines, traced (step 14c, rpg_map_river_trace), with the same margin
       rtr AS MATERIALIZED (SELECT t.x, t.y, t.k, t.seg FROM public.rpg_map_river_trace(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) t),
       -- the battle grid: the water under the roads and the fords (step 11), where it has roads or water
       wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_flow(v_l.level, v_x0, v_y0, v_cols, v_rows) w
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       fd AS MATERIALIZED (SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
       -- (more terrain step 2a) the battle grid: rapids and waterfalls under its river water (rpg_map_rush)
       ru AS MATERIALIZED (SELECT r.x, r.y, r.rush FROM public.rpg_map_rush(v_l.level, v_x0, v_y0, v_cols, v_rows) r
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('water', 'deep'))),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, c.lie, rv.line, rv.px, rv.py, bl.value AS blend, st.mountains AS cliff_m, st.hills AS cliff_h,
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks,
                CASE WHEN c.kind = 'town' OR (v_l.level = 7 AND c.kind IN ('road', 'pass')) THEN tg.id END AS town,
                -- (step 3) a road, market place, street or lane square of a town, city or great city is paved
                CASE WHEN v_l.level = 7 AND c.kind IN ('road', 'pass') AND tg.kind IN ('town', 'city', 'great_city')
                     THEN CASE WHEN mk.x IS NOT NULL THEN 2 ELSE 1 END END AS paved,
                coalesce(hb.id, ft.house) AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
                CASE WHEN c.kind IN ('road', 'pass') AND wt.depth > 0 THEN 'bridge' WHEN c.kind = 'water' AND fd.x IS NOT NULL THEN 'ford' END AS cross,
                ru.rush
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
           LEFT JOIN fd ON fd.x = c.x AND fd.y = c.y
           LEFT JOIN ru ON ru.x = c.x AND ru.y = c.y
           LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
           LEFT JOIN public.rpg_map_cliffs(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
           LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
           LEFT JOIN tm ON tm.x = c.x AND tm.y = c.y
           LEFT JOIN lmm ON lmm.x = c.x AND lmm.y = c.y
           LEFT JOIN tg ON tg.x = c.x AND tg.y = c.y
           LEFT JOIN hb ON hb.x = c.x AND hb.y = c.y
           LEFT JOIN ft ON ft.x = c.x AND ft.y = c.y
           LEFT JOIN mk ON mk.x = c.x AND mk.y = c.y
          CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
          -- the cell itself counted round the world, for a block that runs past the east or west end
          CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx)
  SELECT (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'x', cl.x - v_x0 + 1, 'y', cl.y - v_y0 + 1,
                   'name', public.rpg_square_name(cl.x - v_x0 + 1, cl.y - v_y0 + 1),
                   -- a cell of a village, town or city comes as a place, its place the settlement, so it is drawn and
                   -- named like a place with ground
                   'kind', CASE WHEN NOT cl.seen THEN 'unknown' WHEN cl.town IS NOT NULL AND cl.kind = 'town' THEN 'place' ELSE cl.kind END,
                   -- (step 3) a paved square of a town or city: 1 a street, 2 the market place
                   'paved', CASE WHEN cl.seen THEN cl.paved END,
                   'place', CASE WHEN cl.seen THEN coalesce(cl.town, cl.place_id::text) END,
                   -- a landmark seen from far is marked even in a cell not found yet (step 12b)
                   'marks', CASE WHEN (cl.seen AND (cardinality(cl.marks) > 0 OR cl.towns IS NOT NULL)) OR cl.lmarks IS NOT NULL
                                 THEN CASE WHEN cl.seen THEN to_jsonb(cl.marks) || coalesce(cl.towns, '[]'::jsonb) ELSE '[]'::jsonb END || coalesce(cl.lmarks, '[]'::jsonb) END,
                   'cost', CASE WHEN cl.seen THEN cl.penalty END,
                   'hard', CASE WHEN cl.seen AND (cl.penalty IS NOT NULL OR cl.kind = 'deep') AND cl.hard IS NOT NULL THEN least(floor(cl.hard * 10), 9)::integer END,
                   -- the battle grid's mountains and hills: how near the square is to the middle line of its chain, in
                   -- thousandths of a ground roll below it (0 on the line; rpg_map_blend part 1, the roll that makes them), so
                   -- the page can tell which way is uphill and draw the slope (Peter 2026-10-04: a mountain side)
                   'rise', CASE WHEN cl.seen AND cl.kind IN ('mountains', 'hills') AND cl.blend IS NOT NULL THEN round(-abs(cl.blend) * 1000)::integer END,
                   -- the battle grid's cliffs: how steep, in degrees (rpg_map_cliffs: a mountain cliff or a gorge wall; step 7c,
                   -- canyons), so the page draws the rock face
                   'cliff', CASE WHEN cl.seen THEN round(CASE cl.kind WHEN 'mountains' THEN cl.cliff_m WHEN 'hills' THEN cl.cliff_h END)::integer END,
                   -- a square a house stands on (step 8c): its wall or roof, the metres it climbs, how steep, the difficulty
                   'climb', CASE WHEN cl.seen AND cl.part IS NOT NULL
                                 THEN jsonb_build_array(cl.part, round(cl.climb_rise::numeric, 1), round(cl.climb_angle)::integer, cl.climb_dif,
                                                        public.rpg_map_climb_words(cl.part, cl.climb_angle)) END,
                   -- a square of a place to go into walked like the ground (step 12c): floor, hearth, altar or mouth
                   'feature', CASE WHEN cl.seen AND cl.part IS NULL THEN cl.feature END,
                   'river', CASE WHEN cl.seen AND cl.line > 0 AND cl.kind NOT IN ('water', 'deep', 'sea')
                                 THEN jsonb_build_array(cl.line, round(cl.px * 1000)::integer, round(cl.py * 1000)::integer) END,
                   -- the battle grid: a bridge over the water, or a ford through it (step 11)
                   'cross', CASE WHEN cl.seen THEN cl.cross END,
                   -- (more terrain step 2a) the battle grid: river water running fast, rapids, or falling, a waterfall
                   'rush', CASE WHEN cl.seen AND cl.kind IN ('water', 'deep') AND cl.line IS NOT NULL AND cl.cross IS NULL THEN cl.rush END,
                   -- the battle grid: what lies on the square (step 14f-battle; rpg_map_lie): boulder, log or reeds
                   'lie', CASE WHEN cl.seen THEN cl.lie END,
                   'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || cl.wx::text || '-' || cl.y::text END,
                   'to', jsonb_build_array(cl.wx::bigint * v_l.cell + v_l.cell / 2 + 1, cl.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
                 ORDER BY cl.y, cl.x)
            FROM cl),
         -- the villages, towns and cities shown: a mark on a cell that is seen, or ground on one
         (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1,
                                                     v_l.level = 4 AND q.kind IN ('town', 'city', 'great_city'), q.ground)
                           ORDER BY q.n, q.name)
            FROM (SELECT tw.id, tw.kind, tw.name, tw.people, tw.x, tw.y, tw.r, array_position(ARRAY['great_city', 'city', 'town', 'village'], tw.kind) AS n, gt.g AS ground
                    FROM tw CROSS JOIN gt JOIN cl ON cl.x = floor(tw.x::double precision / v_l.cell)::integer AND cl.y = floor(tw.y::double precision / v_l.cell)::integer
                   WHERE cl.seen
                  UNION ALL
                  SELECT DISTINCT ON (tg.id) tg.id, tg.kind, tg.name, tg.people, tg.tx, tg.ty, tg.r, array_position(ARRAY['great_city', 'city', 'town', 'village'], tg.kind), gt.g
                    FROM tg CROSS JOIN gt JOIN cl ON cl.x = tg.x AND cl.y = tg.y
                   WHERE cl.seen AND cl.town IS NOT NULL) q),
         -- what grows at the sites of this grid, for its roads
         (SELECT jsonb_object_agg(tw.id, tw.kind) FROM tw),
         -- where a road is drawn (step 8b): found, and not the sea
         (SELECT jsonb_object_agg(cl.x || ',' || cl.y, 1) FROM cl WHERE cl.seen AND cl.kind <> 'sea'),
         -- the houses with a square that is seen (step 8c)
         (SELECT array_agg(DISTINCT cl.house) FROM cl WHERE cl.seen AND cl.house IS NOT NULL),
         -- the rivers near each cell, for the crossings (step 11): size, how far (squares) and which way (cells) the line lies
         (SELECT jsonb_agg(jsonb_build_array(r.x, r.y, r.k, round(r.dist::numeric, 1), round(r.px::numeric, 4), round(r.py::numeric, 4)))
            FROM rva r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell),
         -- the traced pieces of the rivers near the block, for the crossings (step 14c): size, ends in cells of the grid
         (SELECT jsonb_agg(jsonb_build_array(r.k, round(r.seg[1]::numeric, 4), round(r.seg[2]::numeric, 4), round(r.seg[3]::numeric, 4), round(r.seg[4]::numeric, 4)))
            FROM rtr r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4)),
         -- the rivers drawn as lines (step 14c): each piece of a traced line in a cell shown that is not water, its size
         -- and ends in thousandths of a cell from the block's first cell
         (SELECT jsonb_agg(jsonb_build_array(r.k, round((r.seg[1] - v_x0) * 1000)::integer, round((r.seg[2] - v_y0) * 1000)::integer,
                                             round((r.seg[3] - v_x0) * 1000)::integer, round((r.seg[4] - v_y0) * 1000)::integer) ORDER BY r.k, r.x, r.y, r.seg[1], r.seg[2], r.seg[3], r.seg[4])
            FROM rtr r JOIN cl ON cl.x = r.x AND cl.y = r.y
           -- (step 14f1) a great river over the sea too: it runs on into the sea cell it flows into, and the Maps tab clips
           -- every river to the coast it draws, so its mouth meets the shore at every zoom
           WHERE cl.seen AND cl.kind NOT IN ('water', 'deep') AND (cl.kind <> 'sea' OR r.k = 2)),
         -- the landmarks shown (step 12b), biggest first
         (SELECT jsonb_agg(public.rpg_map_landmark_entry(ls.id, ls.rank, ls.kind, ls.icon, ls.words, ls.name, ls.x, ls.y, ls.height, ls.across,
                                                         v_l.level, v_gx0, v_gy0, v_gx1, v_gy1) ORDER BY ls.rank, ls.name)
            FROM ls WHERE ls.shown),
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown),
         -- the caves and mines of the grid, for the world under the ground (step 12d)
         -- and the holes the place cards make (rpg_map_place_holes, Peter 2026-10-10), known like a place shown
         (SELECT jsonb_agg(z.e) FROM (SELECT jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near) AS e FROM ls WHERE ls.kind IN ('cave', 'mine')
                                      UNION ALL
                                      SELECT jsonb_build_array(h.id, h.rank, h.kind, h.x, h.y, h.height, h.across, true)
                                        FROM public.rpg_map_place_holes(v_gx0, v_gy0, v_gx1, v_gy1) h WHERE v_l.level BETWEEN 2 AND 6) z),
         -- (storeys step) the upper floors and cellars (floor -1) of the houses whose squares are seen: [floor, x, y, part], x and y from the
         -- block's first square as the cells count them
         (SELECT jsonb_agg(jsonb_build_array(b.floor, b.x - v_x0 + 1, b.y - v_y0 + 1, b.part) ORDER BY b.floor, b.y, b.x)
            FROM (SELECT bsq.x, bsq.y, bsq.floor, bsq.part FROM bsq WHERE bsq.floor <> 0
                  -- (towers step) and the floors of the towers and keeps (rpg_map_landmark_floors)
                  UNION ALL
                  SELECT lf.x, lf.y, lf.floor, lf.part FROM public.rpg_map_landmark_floors(v_x0, v_y0, v_cols, v_rows) lf
                   WHERE v_l.level = 7 AND lf.floor <> 0) b
            JOIN cl ON cl.x = b.x AND cl.y = b.y WHERE cl.seen)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_rsegs, v_rlines, v_lands, v_lmk, v_caves, v_floors;

  -- the world under the ground (step 12d): its passages and its great halls
  -- (step 14a) each passage also carries how wide it runs at its middle (rpg_map_under_size, in thousandths of a cell),
  -- and rooms = the room at each node a passage reaches (rpg_map_under_room: a great hall, a chamber, the far end of a
  -- cave or a mine), each [x, y, half-width (thousandths of a cell), the eight knots of its edge (thousandths)], so the
  -- map draws tunnels and caves at their true size where that size shows
  IF v_l.level BETWEEN 2 AND 6 THEN
    WITH u AS MATERIALIZED (
           SELECT u.*, (SELECT c ->> 2 FROM jsonb_array_elements(coalesce(v_caves, '[]'::jsonb)) c
                         WHERE c ->> 0 IN (split_part(u.a, ':', 2), split_part(u.b, ':', 2)) LIMIT 1) AS skind
             FROM public.rpg_map_underground(v_l.level, v_x0, v_y0, v_cols, v_rows, v_caves, v_gm) u
            -- (step 14a2, Peter 2026-10-07 2B) the Continent and Country grids show the Deeps alone: the caves, mines and
            -- their shafts show from the Region grid down, where they can be seen
            WHERE v_l.level >= 4 OR u.kind IN ('deep', 'hall')),
         sq AS (SELECT t.sq FROM public.rpg_map_under_lattice() t),
         nd AS (SELECT DISTINCT ON (n.node) n.node, n.x, n.y, n.skind
                  FROM (SELECT u.a AS node, u.ax AS x, u.ay AS y, u.skind FROM u
                        UNION ALL SELECT u.b, u.bx, u.by, u.skind FROM u WHERE u.kind <> 'hall') n
                 WHERE n.node NOT LIKE 'mouth:%'
                 ORDER BY n.node, n.skind NULLS LAST)
    SELECT jsonb_build_object(
             'lines', coalesce((SELECT jsonb_agg(jsonb_build_array(u.kind, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell,
                                                                   (u.bx - v_gx0) * 1000 / v_l.cell, (u.by - v_gy0) * 1000 / v_l.cell,
                                                                   round(u.ad)::integer, round(u.bd)::integer, round(u.bend * 100)::integer,
                                                                   round((SELECT sqrt(z.w_low * z.w_high) FROM public.rpg_map_under_size(u.kind, u.skind,
                                                                            CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END) z)
                                                                         / sq.sq * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(jsonb_build_array(round((r.x - v_gx0) * 1000 / v_l.cell)::integer, round((r.y - v_gy0) * 1000 / v_l.cell)::integer,
                                                                                                       round(r.half * 1000 / v_l.cell)::integer) ORDER BY r.n)
                                                                      FROM public.rpg_map_under_trace(u.kind, u.a, u.b, u.ax, u.ay, u.bx, u.by, u.bend, u.skind,
                                                                                                      v_gx0, v_gy0, v_gx1, v_gy1, (v_gx1 - v_gx0) / 240.0) r),
                                                                   (SELECT jsonb_build_array(round(w.part * 1000)::integer, round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water(u.kind, u.skind, CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END,
                                                                                                      u.a || '|' || u.b) w WHERE u.kind <> 'shaft')))
                                  FROM u CROSS JOIN sq WHERE u.kind <> 'hall'), '[]'::jsonb),
             'halls', coalesce((SELECT jsonb_agg(jsonb_build_array(u.name, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell, round(u.ad)::integer)
                                               ORDER BY u.name) FROM u WHERE u.kind = 'hall'), '[]'::jsonb),
             'rooms', coalesce((SELECT jsonb_agg(jsonb_build_array((nd.x - v_gx0) * 1000 / v_l.cell, (nd.y - v_gy0) * 1000 / v_l.cell, round(r.r * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(r.knots) AS k),
                                                                   (SELECT jsonb_build_array(round(w.dx * 1000)::integer, round(w.dy * 1000)::integer, round(w.part * 1000)::integer,
                                                                                             (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(w.knots) AS k), round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water('room', nd.skind, nd.node, nd.node) w)) ORDER BY nd.node)
                                  FROM nd CROSS JOIN LATERAL public.rpg_map_under_room(nd.node, nd.skind) r), '[]'::jsonb))
      INTO v_under;
  END IF;

  -- the battle grid under the ground (step 12d3)
  IF v_l.level = 7 THEN
    SELECT jsonb_build_object('lines', '[]'::jsonb, 'halls', '[]'::jsonb,
             'squares', coalesce(jsonb_agg(jsonb_build_array(q.x - v_x0, q.y - v_y0, q.part, q.pct, q.water, round(q.down / 0.3048)::integer) ORDER BY q.y, q.x), '[]'::jsonb))
      INTO v_under
      FROM public.rpg_map_under_squares(v_x0, v_y0, v_cols, v_rows, (
             SELECT coalesce(jsonb_agg(w.j), '[]'::jsonb) FROM (
               SELECT jsonb_build_object('kind', u.kind, 'a', u.a, 'b', u.b, 'ax', u.ax, 'ay', u.ay, 'bx', u.bx, 'by', u.by, 'ad', u.ad, 'bd', u.bd, 'bend', u.bend) AS j
                 FROM public.rpg_map_underground(7, v_x0, v_y0, v_cols, v_rows, NULL, v_gm) u
               UNION ALL
               SELECT l.j
                 FROM public.rpg_session_participants p
                 JOIN public.rpg_sessions s ON s.id = p.session_id AND s.on_map AND s.status <> 'ended'
                CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_under_layer(p.under_at, p.under_to)) AS l(j)
                WHERE p.under_at IS NOT NULL AND (v_gm OR p.creature_id IS NULL)
                  AND p.pos_x - 1 BETWEEN v_x0 - 40 AND v_x0 + v_cols + 40 AND p.pos_y - 1 BETWEEN v_y0 - 40 AND v_y0 + v_rows + 40) w)) q;
  END IF;

  -- the houses of the battle grid (step 8c): every one with a square seen here, drawn whole as far as the grid goes
  IF v_l.level = 7 AND cardinality(v_hseen) > 0 THEN
    SELECT jsonb_agg(jsonb_build_object(
             'id', h.id, 'roof', h.roof,
             -- (step 14e) what the building is (its id's first letter: h a house, b a barn, c a church, k a cathedral) and
             -- which of its parts this is (the letter after the dot; none for the first part)
             'use', CASE left(h.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(h.id, '.', 2), ''),
             'x', round((h.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((h.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(h.ux * 1000)::integer, round(h.uy * 1000)::integer),
             'len', round(2 * h.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * h.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(h.eaves::numeric, 1), 'pitch', round(h.pitch)::integer, 'storeys', h.storeys) ORDER BY h.id)
      INTO v_houses
      FROM public.rpg_map_buildings(v_l.level, v_x0, v_y0, v_cols, v_rows) h
     -- every part of a building with a square seen (step 14e)
     WHERE split_part(h.id, '.', 1) IN (SELECT split_part(x, '.', 1) FROM unnest(v_hseen) AS x);
  END IF;

  -- the buildings of the District grid (step 14e, Peter 2026-10-07 21:05: cities need more building variety; the City
  -- and District grids show real buildings): the same buildings as the battle grids under it, saved on the grid's row
  -- of the saved map once worked out in the background (rpg_map_district_buildings; a great city's take longer than a
  -- read may run). Each drawn whole where the kids login has found a cell any part of it stands in; x, y, len and wide
  -- in thousandths of a District cell. Not saved yet: houses_pending, and the Maps tab draws the town symbols and asks
  -- again a few seconds later.
  IF v_l.level = 6 THEN
    v_hlist := public.rpg_map_district_buildings(v_x0, v_y0, v_cols, v_rows);
    v_hpend := v_hlist IS NULL;
  END IF;
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH b AS MATERIALIZED (
           SELECT h.* FROM jsonb_to_recordset(v_hlist) AS h(id text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                            half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer)),
         sc AS (SELECT (c.v ->> 'x')::integer AS x, (c.v ->> 'y')::integer AS y FROM jsonb_array_elements(coalesce(v_cells, '[]'::jsonb)) AS c(v)
                 WHERE c.v ->> 'kind' IS DISTINCT FROM 'unknown'),
         sb AS (SELECT DISTINCT split_part(b.id, '.', 1) AS base FROM b
                 WHERE v_gm OR EXISTS (SELECT 1 FROM sc WHERE sc.x = floor((b.cx - v_gx0) / v_l.cell)::integer + 1 AND sc.y = floor((b.cy - v_gy0) / v_l.cell)::integer + 1))
    SELECT jsonb_agg(jsonb_build_object(
             'id', b.id, 'roof', b.roof,
             'use', CASE left(b.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(b.id, '.', 2), ''),
             'x', round((b.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((b.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(b.ux * 1000)::integer, round(b.uy * 1000)::integer),
             'len', round(2 * b.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * b.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(b.eaves::numeric, 1), 'pitch', round(b.pitch)::integer, 'storeys', b.storeys) ORDER BY b.id)
      INTO v_houses
      FROM b WHERE split_part(b.id, '.', 1) IN (SELECT sb.base FROM sb);
  END IF;

  IF v_l.level < v_last AND (v_l.level = 1 OR p_place IS NOT NULL) THEN
    -- drawn fine: every cell of the grid one level down inside the block
    SELECT v_l.cell / l.cell INTO v_sub FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1;
    v_dc := v_cols * v_sub;
    v_dr := v_rows * v_sub;
    IF NOT v_gm THEN
      SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
        FROM public.rpg_map_found(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) f;
    END IF;
    v_rm := CASE WHEN v_l.level + 1 = 6 THEN 3 WHEN v_l.level + 1 = 5 THEN 2 WHEN v_l.level + 1 = 4 THEN 1 ELSE 0 END;
    v_ry0 := greatest(v_y0 * v_sub - v_rm, 0);
    v_ry1 := least(v_y0 * v_sub + v_dr + v_rm, (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1));
    -- the grids the fine drawing reads, saved the first time (step 13): the World grid draws every Continent grid
    PERFORM public.rpg_map_cache_fill(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr);
    WITH kn AS MATERIALIZED (
           SELECT DISTINCT w.x, w.y
             FROM unnest(v_known) AS n(id)
            CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) w
            WHERE NOT v_gm),
         d0 AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr)),
         -- the villages, towns and cities of the detail (step 8). A place shown whole on the Continent or Country grid is
         -- drawn about as far out as a Country grid, so its detail marks the cities, as the Country grid does: a detail
         -- of Country cells decides them by its own cells, a detail of Region cells by the Country cells of the grid
         -- itself. A finer detail shows their ground (dg).
         dt AS MATERIALIZED (
           SELECT t.* FROM public.rpg_map_towns(3, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr, (SELECT jsonb_object_agg(d0.x || ',' || d0.y, d0.kind) FROM d0)) t
            WHERE v_l.level + 1 = 3 AND t.kind IS NOT NULL
           UNION ALL
           SELECT t.* FROM public.rpg_map_towns(3, v_x0, v_y0, v_cols, v_rows, NULL) t
            WHERE v_l.level + 1 = 4 AND t.kind IS NOT NULL
           UNION ALL
           -- the World grid (step 14d4): the greatest cities of the world, kept on its saved row (rpg_map_cache_warm)
           SELECT t.id, t.kind, t.name, t.people, t.x, t.y, t.r, NULL::double precision[]
             FROM public.rpg_map_cache m
            CROSS JOIN LATERAL jsonb_to_recordset(m.notes -> 'cities') AS t(id text, kind text, name text, people integer, x bigint, y bigint, r double precision)
            WHERE v_l.level = 1 AND m.level = 1 AND m.gx = 0 AND m.gy = 0),
         dm AS (SELECT floor(dt.x::double precision / (v_l.cell / v_sub))::integer AS x, floor(dt.y::double precision / (v_l.cell / v_sub))::integer AS y,
                       jsonb_agg(dt.id ORDER BY dt.id) AS ids
                  FROM dt GROUP BY 1, 2),
         gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
         dg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) t WHERE v_l.level + 1 >= 5),
         rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub - v_rm, v_ry0, v_dc + 2 * v_rm, v_ry1 - v_ry0) r),
         -- the landmarks of the grid (step 12b), each in the cell of the detail its middle stands in
         dlm AS (SELECT floor((e.v ->> 'x')::double precision / (v_l.cell / v_sub))::integer AS x, floor((e.v ->> 'y')::double precision / (v_l.cell / v_sub))::integer AS y,
                        jsonb_agg(e.v -> 'id' ORDER BY e.v ->> 'id') AS ids
                   FROM jsonb_array_elements(coalesce(v_lmk, '[]'::jsonb)) AS e(v) GROUP BY 1, 2),
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, dlm.ids AS lmarks, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
             LEFT JOIN dm ON dm.x = c.x AND dm.y = c.y
             LEFT JOIN dg ON dg.x = c.x AND dg.y = c.y
             LEFT JOIN dlm ON dlm.x = c.x AND dlm.y = c.y),
         -- the places drawn in the detail, cards first, then the villages, towns and cities whose ground it shows
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.o, q.sort_order, q.name), '{}'::text[]) AS ids
                 FROM (SELECT DISTINCT c.id::text AS id, 0 AS o, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen
                       UNION ALL
                       SELECT DISTINCT d.town, 1, 0, d.town FROM d WHERE d.seen AND d.town IS NOT NULL) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id::text))
                                            WHEN d.town IS NOT NULL THEN chr(255 + array_position(u.ids, d.town))
                                            ELSE g.ch END, '' ORDER BY d.x) AS line,
                       string_agg(CASE WHEN d.seen AND (d.penalty IS NOT NULL OR d.kind = 'deep') AND d.hard IS NOT NULL THEN least(floor(d.hard * 10), 9)::integer::text
                                       ELSE '-' END, '' ORDER BY d.x) AS hard,
                       string_agg(CASE WHEN d.seen AND d.line > 0 AND d.kind NOT IN ('water', 'deep', 'sea') THEN d.line::text ELSE '0' END, '' ORDER BY d.x) AS rivers,
                       string_agg(CASE WHEN d.seen AND d.line > 0 THEN least(9, greatest(0, round((d.px + 0.5) * 9)))::integer::text ELSE '0' END, '' ORDER BY d.x) AS river_x,
                       string_agg(CASE WHEN d.seen AND d.line > 0 THEN least(9, greatest(0, round((d.py + 0.5) * 9)))::integer::text ELSE '0' END, '' ORDER BY d.x) AS river_y
                  FROM d CROSS JOIN u
                  LEFT JOIN public.rpg_map_grounds() g ON g.kind = d.kind
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'wrap', p_place IS NULL, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y),
                              'hard', CASE WHEN bool_or(ln.hard ~ '[0-9]') THEN jsonb_agg(ln.hard ORDER BY ln.y) END,
                              'rivers', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.rivers ORDER BY ln.y) END,
                              'river_x', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.river_x ORDER BY ln.y) END,
                              'river_y', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.river_y ORDER BY ln.y) END,
                              'marks', (SELECT jsonb_object_agg((d.x - v_x0 * v_sub)::text || ',' || (d.y - v_y0 * v_sub)::text,
                                                                CASE WHEN d.seen THEN to_jsonb(d.marks) || coalesce(d.towns, '[]'::jsonb) ELSE '[]'::jsonb END || coalesce(d.lmarks, '[]'::jsonb))
                                          FROM d WHERE (d.seen AND (cardinality(d.marks) > 0 OR d.towns IS NOT NULL)) OR d.lmarks IS NOT NULL)),
           -- the villages, towns and cities the detail shows, placed on this grid like a place
           (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1, false, q.ground))
              FROM (SELECT dt.id, dt.kind, dt.name, dt.people, dt.x, dt.y, dt.r, gt.g AS ground
                      FROM dt CROSS JOIN gt JOIN d ON d.x = floor(dt.x::double precision / (v_l.cell / v_sub))::integer AND d.y = floor(dt.y::double precision / (v_l.cell / v_sub))::integer
                     WHERE d.seen
                    UNION ALL
                    SELECT DISTINCT ON (dg.id) dg.id, dg.kind, dg.name, dg.people, dg.tx, dg.ty, dg.r, gt.g
                      FROM dg CROSS JOIN gt JOIN d ON d.x = dg.x AND d.y = dg.y
                     WHERE d.seen AND d.town IS NOT NULL) q),
           (SELECT jsonb_object_agg(dt.id, dt.kind) FROM dt),
           (SELECT jsonb_object_agg(d.x || ',' || d.y, 1) FROM d WHERE d.seen AND d.kind <> 'sea'),
           (SELECT jsonb_agg(jsonb_build_array(r.x, r.y, r.k, round(r.dist::numeric, 1), round(r.px::numeric, 4), round(r.py::numeric, 4)))
              FROM rva r WHERE v_l.level + 1 BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell / v_sub)
      INTO v_detail, v_dtowns, v_dkinds, v_dshown, v_drivs
      FROM ln;
  END IF;

  -- a village, town or city both marked on the grid and drawn in its detail is told once
  IF v_dtowns IS NOT NULL THEN
    SELECT jsonb_agg(q.e ORDER BY q.n) INTO v_towns
      FROM (SELECT DISTINCT ON (e.value ->> 'id') e.value AS e, e.n
              FROM jsonb_array_elements(coalesce(v_towns, '[]'::jsonb) || v_dtowns) WITH ORDINALITY AS e(value, n)
             ORDER BY e.value ->> 'id', e.n) q;
  END IF;

  -- the roads drawn (step 8b; rpg_map_roads): highways where cities are marked (the Country grid, or a place shown whole
  -- about as far out), all three from the Region grid down to the District grid; the battle grid has them as ground.
  -- Read on what is drawn (the detail of a place shown whole, else the grid), with what grows at its sites when the
  -- read has it (its cities or towns); a detail of Region cells that marks only cities reads its highways on the grid.
  -- Every stretch whose line may reach the block (step 10b; rpg_map_roads looks that far): its points
  -- (rpg_map_road_lines) make the pieces, cut where they leave the cells shown.
  v_what := CASE WHEN v_detail IS NULL THEN CASE WHEN v_l.level = 3 THEN 1 WHEN v_l.level BETWEEN 4 AND v_last - 1 THEN 7 ELSE 0 END
                 WHEN v_l.level = 1 THEN 0
                 ELSE CASE WHEN v_l.level + 1 IN (3, 4) THEN 1 WHEN v_l.level + 1 BETWEEN 5 AND v_last - 1 THEN 7 ELSE 0 END END;
  IF v_what > 0 THEN
    SELECT jsonb_agg(round(1000 * s.value / q.cell)::integer ORDER BY s.key)
      INTO v_rw
      FROM (SELECT CASE WHEN v_detail IS NULL THEN v_l.cell ELSE v_l.cell / v_sub END::numeric AS cell) q
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
       AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width', 'map_road_4_width', 'map_road_5_width', 'map_road_6_width');
    WITH g AS (SELECT CASE WHEN v_detail IS NULL THEN v_l.cell ELSE v_l.cell / v_sub END::double precision AS cell,
                      CASE WHEN v_detail IS NULL THEN v_x0 ELSE v_x0 * v_sub END AS x0, CASE WHEN v_detail IS NULL THEN v_y0 ELSE v_y0 * v_sub END AS y0,
                      CASE WHEN v_detail IS NULL THEN v_cols ELSE v_dc END AS cols, CASE WHEN v_detail IS NULL THEN v_rows ELSE v_dr END AS rows,
                      coalesce(CASE WHEN v_detail IS NULL THEN v_shown ELSE v_dshown END, '{}'::jsonb) AS shown,
                      CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END AS sub,
                      CASE WHEN v_detail IS NULL THEN v_l.level ELSE v_l.level + 1 END AS level),
         lg AS (SELECT row_number() OVER () AS n, r.*
                  FROM public.rpg_map_roads(CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_l.level ELSE v_l.level + 1 END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_x0 ELSE v_x0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_y0 ELSE v_y0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_cols ELSE v_dc END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_rows ELSE v_dr END,
                                            v_what, CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_kinds ELSE v_dkinds END, 0) r),
         -- the points of every line at once, in cells of what is drawn from the first cell, and whether each lies in a
         -- cell shown
         la AS (SELECT array_agg(lg.class ORDER BY lg.n) AS class, array_agg(lg.ax ORDER BY lg.n) AS ax, array_agg(lg.ay ORDER BY lg.n) AS ay,
                       array_agg(lg.bx ORDER BY lg.n) AS bx, array_agg(lg.by ORDER BY lg.n) AS by, array_agg(lg.a ORDER BY lg.n) AS a, array_agg(lg.b ORDER BY lg.n) AS b
                  FROM lg HAVING count(*) > 0),
         lp AS MATERIALIZED (
           SELECT p.i AS n, la.class[p.i] AS class, la.a[p.i] AS a, la.b[p.i] AS b, p.n AS i, p.x / g.cell - g.x0 AS u, p.y / g.cell - g.y0 AS v,
                  floor(p.x / g.cell - g.x0) BETWEEN 0 AND g.cols - 1 AND floor(p.y / g.cell - g.y0) BETWEEN 0 AND g.rows - 1
                  AND g.shown ? (floor(p.x / g.cell)::bigint || ',' || floor(p.y / g.cell)::bigint) AS ok
             FROM la CROSS JOIN g
            CROSS JOIN LATERAL public.rpg_map_road_lines(la.class, la.ax, la.ay, la.bx, la.by, la.a, la.b, g.cell) p),
         ls AS (SELECT lp.*, lag(lp.ok) OVER w AS pok, lead(lp.ok) OVER w AS nok,
                       lag(lp.u) OVER w AS pu, lag(lp.v) OVER w AS pv, lead(lp.u) OVER w AS nu, lead(lp.v) OVER w AS nv
                  FROM lp WINDOW w AS (PARTITION BY lp.n ORDER BY lp.i)),
         -- the points shown, in runs that follow on from one another; a run ends at the edge of its last cell shown
         lr AS (SELECT ls.*, sum(CASE WHEN NOT coalesce(ls.pok, false) THEN 1 ELSE 0 END) OVER (PARTITION BY ls.n ORDER BY ls.i) AS run FROM ls WHERE ls.ok),
         pc AS (SELECT lr.n, lr.class, lr.run, 2 * lr.i AS o, lr.u, lr.v FROM lr
                UNION ALL
                SELECT lr.n, lr.class, lr.run, 2 * lr.i + e.d, lr.u + e.t * (e.qu - lr.u), lr.v + e.t * (e.qv - lr.v)
                  FROM lr
                 CROSS JOIN LATERAL (VALUES (-1, lr.pok, lr.pu, lr.pv), (1, lr.nok, lr.nu, lr.nv)) AS q(d, qok, qu, qv)
                 CROSS JOIN g
                 -- where the run ends toward that point (step 12a): it runs on through the cells shown and stops where
                 -- the line first meets a cell not shown or leaves what is drawn (it stopped at the edge of the cell of the last
                 -- point, up to a few cells short where the points lie far apart)
                 CROSS JOIN LATERAL (SELECT q.d, q.qu, q.qv, coalesce(min(s.t0) FILTER (WHERE NOT s.ok), 1) AS t
                                       FROM (SELECT b.t0,
                                                    floor(lr.u + (b.t0 + b.t1) / 2 * (q.qu - lr.u)) BETWEEN 0 AND g.cols - 1
                                                    AND floor(lr.v + (b.t0 + b.t1) / 2 * (q.qv - lr.v)) BETWEEN 0 AND g.rows - 1
                                                    AND g.shown ? ((floor(lr.u + (b.t0 + b.t1) / 2 * (q.qu - lr.u)) + g.x0)::bigint || ',' || (floor(lr.v + (b.t0 + b.t1) / 2 * (q.qv - lr.v)) + g.y0)::bigint) AS ok
                                               FROM (SELECT k.t AS t0, lead(k.t) OVER (ORDER BY k.t) AS t1
                                                       FROM (SELECT 0::double precision AS t
                                                             UNION SELECT (gx - lr.u) / (q.qu - lr.u) FROM generate_series(floor(least(lr.u, q.qu))::integer + 1, floor(greatest(lr.u, q.qu))::integer) AS gx WHERE q.qu <> lr.u
                                                             UNION SELECT (gy - lr.v) / (q.qv - lr.v) FROM generate_series(floor(least(lr.v, q.qv))::integer + 1, floor(greatest(lr.v, q.qv))::integer) AS gy WHERE q.qv <> lr.v
                                                             UNION SELECT 1::double precision) k) b
                                              WHERE b.t1 > b.t0) s) e
                 WHERE q.qu IS NOT NULL AND NOT q.qok),
         -- the crossings (step 11), from the Region grid down to the District grid: where a piece of a road line, from
         -- one point to the next, passes from one side of a river line to the other. The river near each cell is known
         -- from the middle of the cell (rpg_map_rivers: how far the line lies and which way), so within a cell the line
         -- is taken as straight: the signed distance of both points from it, in the frame of the cell the first point
         -- lies in (the second where the first cell has no river near, or its middle sits on the line and gives no
         -- direction); a change of sign is a crossing, at the point between them where the distance is 0, shown when
         -- that point lies in a cell shown. Then the planned fords off the roads (rpg_map_fords): rivers from the City
         -- grid down, streams from the District grid down, in cells shown.
         rv AS MATERIALIZED (
           SELECT (e.v ->> 0)::integer AS x, (e.v ->> 1)::integer AS y, (e.v ->> 2)::integer AS k, (e.v ->> 3)::double precision / g.cell AS d,
                  (e.v ->> 4)::double precision AS px, (e.v ->> 5)::double precision AS py,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || (e.v ->> 2) || '_width')::double precision / g.cell AS width
             FROM g CROSS JOIN jsonb_array_elements(coalesce(CASE WHEN v_detail IS NULL THEN v_rivs ELSE v_drivs END, '[]'::jsonb)) AS e(v)
            WHERE g.level BETWEEN 4 AND 6 AND (e.v ->> 3)::double precision / g.cell >= 0.02),
         -- (step 14c) a river traced as a line crosses a road where a piece of the road meets a piece of the river; the
         -- straight-in-a-cell rule below is kept for rivers that are water on this grid (as wide as its cells), and for a
         -- view drawn from its detail (the world, a place shown whole), whose rivers are not traced
         rvw AS MATERIALIZED (SELECT rv.* FROM rv WHERE rv.width >= 1 OR v_detail IS NOT NULL),
         rs AS MATERIALIZED (
           SELECT (e.v ->> 0)::integer AS k, (e.v ->> 1)::double precision - g.x0 AS x1, (e.v ->> 2)::double precision - g.y0 AS y1,
                  (e.v ->> 3)::double precision - g.x0 AS x2, (e.v ->> 4)::double precision - g.y0 AS y2,
                  floor(((e.v ->> 1)::double precision + (e.v ->> 3)::double precision) / 2 - g.x0)::integer AS cu,
                  floor(((e.v ->> 2)::double precision + (e.v ->> 4)::double precision) / 2 - g.y0)::integer AS cv,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || (e.v ->> 0) || '_width')::double precision / g.cell AS width
             FROM g CROSS JOIN jsonb_array_elements(coalesce(CASE WHEN v_detail IS NULL THEN v_rsegs END, '[]'::jsonb)) AS e(v)
            WHERE g.level BETWEEN 4 AND 6),
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rvw WHERE rvw.x = g.x0 + floor(q.ox)::integer AND rvw.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rvw r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rvw)),
         -- the cells each piece of road spans (and a quarter cell round it, where a river piece's middle may lie), to meet the river pieces of those cells
         lc AS (SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, cu, cv
                  FROM ls
                 CROSS JOIN LATERAL generate_series(floor(least(ls.u, ls.nu) - 0.25)::integer, floor(greatest(ls.u, ls.nu) + 0.25)::integer) AS cu
                 CROSS JOIN LATERAL generate_series(floor(least(ls.v, ls.nv) - 0.25)::integer, floor(greatest(ls.v, ls.nv) + 0.25)::integer) AS cv
                 WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rs)),
         xt AS (
           SELECT DISTINCT lc.n, lc.class, lc.a, lc.b, lc.u, lc.v, lc.nu, lc.nv, rs.k, rs.width,
                  lc.u + t.t * (lc.nu - lc.u) AS xu, lc.v + t.t * (lc.nv - lc.v) AS xv
             FROM lc
             JOIN rs ON rs.cu = lc.cu AND rs.cv = lc.cv
            CROSS JOIN LATERAL (SELECT (lc.nu - lc.u) * (rs.y2 - rs.y1) - (lc.nv - lc.v) * (rs.x2 - rs.x1) AS dd) q
            CROSS JOIN LATERAL (SELECT ((rs.x1 - lc.u) * (rs.y2 - rs.y1) - (rs.y1 - lc.v) * (rs.x2 - rs.x1)) / q.dd AS t,
                                       ((rs.x1 - lc.u) * (lc.nv - lc.v) - (rs.y1 - lc.v) * (lc.nu - lc.u)) / q.dd AS s) t
            WHERE q.dd <> 0 AND t.t >= 0 AND t.t < 1 AND t.s >= 0 AND t.s < 1),
         xs AS (
           SELECT cx.class, cx.k, cx.a, cx.b, cx.u, cx.v, cx.nu, cx.nv, cx.width, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1
           UNION ALL
           SELECT xt.class, xt.k, xt.a, xt.b, xt.u, xt.v, xt.nu, xt.nv, xt.width, xt.xu, xt.xv FROM xt),
         pf AS (
           SELECT f.k, f.x / g.cell - g.x0 AS xu, f.y / g.cell - g.y0 AS xv, degrees(atan2(f.ux, -f.uy)) AS angle,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || f.k || '_width')::double precision / g.cell AS width
             FROM g
            CROSS JOIN LATERAL public.rpg_map_fords(g.x0 * g.cell, g.y0 * g.cell, (g.x0 + g.cols) * g.cell, (g.y0 + g.rows) * g.cell,
                                                    CASE WHEN g.level = 5 THEN ARRAY[3] ELSE ARRAY[3, 4] END) f
            WHERE g.level IN (5, 6)
              AND EXISTS (SELECT 1 FROM rv WHERE rv.k IN (3, 4) AND rv.d <= 0.7 AND (rv.k = 3 OR g.level = 6)))
    SELECT (SELECT jsonb_agg(q.piece ORDER BY q.class DESC, q.n, q.run)
              FROM (SELECT pc.n, pc.class, pc.run, jsonb_build_array(pc.class) || jsonb_agg(e.val ORDER BY pc.o, e.i) AS piece
                      FROM pc CROSS JOIN g
                     CROSS JOIN LATERAL (VALUES (1, round(pc.u * 1000 / g.sub)::integer), (2, round(pc.v * 1000 / g.sub)::integer)) AS e(i, val)
                     GROUP BY pc.n, pc.class, pc.run
                    HAVING count(*) >= 4) q),
           (SELECT jsonb_agg(q.e ORDER BY q.o, q.k, q.x, q.y)
              FROM (SELECT 1 AS o, xs.k, xs.xu AS x, xs.xv AS y,
                           jsonb_build_array(public.rpg_map_crossing_kind(xs.class, xs.k, xs.a, xs.b), xs.k, xs.class,
                                             round(xs.xu * 1000 / g.sub)::integer, round(xs.xv * 1000 / g.sub)::integer,
                                             round(degrees(atan2(xs.nv - xs.v, xs.nu - xs.u)))::integer, round(xs.width * 1000 / g.sub)::integer) AS e
                      FROM xs CROSS JOIN g
                     -- in the block, or close enough outside it that its bar (half the water and a little more) reaches
                     -- in; the cell of the block nearest to it must be shown
                     CROSS JOIN LATERAL (SELECT least(greatest(floor(xs.xu)::integer, 0), g.cols - 1) AS cu, least(greatest(floor(xs.xv)::integer, 0), g.rows - 1) AS cv) nc
                     WHERE xs.xu BETWEEN -(xs.width / 2 + 0.3) AND g.cols + xs.width / 2 + 0.3
                       AND xs.xv BETWEEN -(xs.width / 2 + 0.3) AND g.rows + xs.width / 2 + 0.3
                       AND g.shown ? ((g.x0 + nc.cu) || ',' || (g.y0 + nc.cv))
                    UNION ALL
                    SELECT 2, pf.k, pf.xu, pf.xv,
                           jsonb_build_array(3, pf.k, 0, round(pf.xu * 1000 / g.sub)::integer, round(pf.xv * 1000 / g.sub)::integer, round(pf.angle)::integer, round(pf.width * 1000 / g.sub)::integer)
                      FROM pf CROSS JOIN g
                     WHERE floor(pf.xu) BETWEEN 0 AND g.cols - 1 AND floor(pf.xv) BETWEEN 0 AND g.rows - 1
                       AND g.shown ? ((g.x0 + floor(pf.xu)::integer) || ',' || (g.y0 + floor(pf.xv)::integer))) q)
      INTO v_roads, v_cross;
  END IF;

  -- (step 3) the District grid's streets: the market places, streets and lanes inside its towns and cities, saved with
  -- its buildings (rpg_map_district_buildings, notes: streets), drawn among the roads as pieces [4 the market place,
  -- its width, x0, y0, ...] and [5 a street or 6 a lane, x0, y0, ...] in thousandths of a District cell (road_width
  -- carries the width of a street and a lane), cut where they leave the cells the kids login has found
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH sv AS (SELECT m.notes -> 'streets' AS j
                  FROM public.rpg_map_cache_grids(6, v_x0, v_y0, v_cols, v_rows) g
                  JOIN public.rpg_map_cache m ON m.level = 6 AND m.gx = g.gx AND m.gy = g.gy LIMIT 1),
         sl AS (SELECT e.v, e.o, (e.v ->> 0)::integer AS class, (e.v ->> 1)::double precision AS half
                  FROM sv CROSS JOIN LATERAL jsonb_array_elements(coalesce(sv.j, '[]'::jsonb)) WITH ORDINALITY AS e(v, o)),
         sp AS (SELECT sl.o, sl.class, sl.half, k.i, (sl.v ->> (2 * k.i + 2))::double precision AS x, (sl.v ->> (2 * k.i + 3))::double precision AS y
                  FROM sl CROSS JOIN LATERAL generate_series(0, (jsonb_array_length(sl.v) - 2) / 2 - 1) AS k(i)),
         sk AS (SELECT sp.*, v_gm OR coalesce(v_shown, '{}'::jsonb) ? (floor(sp.x / v_l.cell)::bigint || ',' || floor(sp.y / v_l.cell)::bigint) AS ok FROM sp),
         sr AS (SELECT sk.*, sum(CASE WHEN sk.ok THEN 0 ELSE 1 END) OVER (PARTITION BY sk.o ORDER BY sk.i) AS run FROM sk)
    SELECT coalesce(v_roads, '[]'::jsonb) || coalesce(jsonb_agg(q.piece ORDER BY q.class, q.o, q.run), '[]'::jsonb) INTO v_roads
      FROM (SELECT sr.o, sr.class, sr.run,
                   CASE WHEN sr.class = 4 THEN jsonb_build_array(4, round(2 * sr.half * 1000 / v_l.cell)::integer) ELSE jsonb_build_array(sr.class) END
                   || jsonb_agg(v.c ORDER BY sr.i, v.n) AS piece
              FROM sr CROSS JOIN LATERAL (VALUES (1, round((sr.x - v_gx0) * 1000 / v_l.cell)::integer), (2, round((sr.y - v_gy0) * 1000 / v_l.cell)::integer)) AS v(n, c)
             WHERE sr.ok GROUP BY sr.o, sr.class, sr.half, sr.run HAVING count(*) >= 4) q;
  END IF;

  IF p_place IS NULL THEN
    SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                          ELSE jsonb_build_object(
                            'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                            'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                     ORDER BY l.level)
      INTO v_crumbs
      FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
     WHERE l.level <= v_l.level;
  ELSE
    -- a place shown whole: the world, the lands that hold its middle (the smallest of each kind, biggest kind first),
    -- then the place
    SELECT jsonb_build_array(jsonb_build_object('label', (SELECT l.name FROM public.rpg_map_ladder() l WHERE l.level = 1), 'view', NULL))
           || coalesce(jsonb_agg(jsonb_build_object('label', q.name, 'view', public.rpg_map_place_link(q.id)) ORDER BY q.place_level), '[]'::jsonb)
           || jsonb_build_array(jsonb_build_object('label', v_pname, 'view', 'p-' || p_place::text))
      INTO v_crumbs
      FROM (SELECT DISTINCT ON (c.place_level) c.id, c.name, c.place_level
              FROM public.rpg_creatures c
             WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
               AND c.place_penalty IS NULL AND c.place_level < v_plevel
               AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
               AND public.rpg_map_covers(v_pcx::double precision, v_pcy::double precision, c.place_x, c.place_y, c.place_w, c.place_h, v_world)
             ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;
  END IF;

  v_scale := public.rpg_map_length_text(v_cols::numeric * v_l.cell)
          || CASE WHEN v_l.level = 1 AND p_place IS NULL THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_band_text('place', c.id) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', CASE WHEN v_gm OR c.id = ANY (v_known) THEN c.lore END,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', public.rpg_map_place_link(c.id),
           'listed', c.place_level = v_list_level
                     AND CASE WHEN p_place IS NOT NULL
                              -- a place shown whole lists the places one level down whose middle lies inside it
                              THEN public.rpg_map_covers(c.place_x::double precision, c.place_y::double precision, v_pcx, v_pcy, v_pw, v_ph, v_world)
                              ELSE public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                          c.place_x, c.place_y, c.place_w, c.place_h, v_world)
                                   -- a place with ground whose natural edge reaches past its oval into this grid
                                   OR (c.place_penalty IS NOT NULL AND EXISTS (SELECT 1 FROM public.rpg_map_within(c.id, v_l.level, v_x0, v_y0, v_cols, v_rows))) END,
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
             AND c.place_penalty IS NULL AND c.place_level <= coalesce(v_plevel - 1, v_l.level)
             AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
             -- the middle of this grid; for a place shown whole, the middle of the place
             AND public.rpg_map_covers(coalesce(v_pcx, (v_gx0 + v_gx1) / 2.0::double precision), coalesce(v_pcy, (v_gy0 + v_gy1) / 2.0::double precision),
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_list_level) q;

  SELECT jsonb_object_agg(g.kind, jsonb_strip_nulls(jsonb_build_object('name', g.name, 'penalty', public.rpg_map_band_text(g.kind))))
    INTO v_grounds
    FROM public.rpg_map_grounds() g;

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
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'icon', public.rpg_icon(p.character_id, coalesce(p.creature_id, ch.template_id)), 'placed', p.pos_x IS NOT NULL,
                      'creature', p.creature_id IS NOT NULL,
                      'out', CASE WHEN p.creature_id IS NOT NULL AND public.rpg_participant_out(p.id) THEN 'out of the fight' END,
                      'fight', public.rpg_map_in_fight(p.id),
                      -- under the ground (step 12d2)
                      'under', CASE WHEN p.under_at IS NOT NULL THEN public.rpg_map_under_where(p.under_at, p.under_to, p.under_done) END,
                      'ways', CASE WHEN p.under_at IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN CASE WHEN p.under_to IS NULL
                                             THEN (SELECT jsonb_agg(jsonb_build_array(w.to_node,
                                                                      public.rpg_map_under_way_words(w.kind, w.skind, w.up, w.metres,
                                                                                                     public.rpg_ticks_at(public.rpg_participant_speed(p.id), w.base),
                                                                                                     w.to_name, w.to_depth, w.to_sea))
                                                                    ORDER BY w.metres)
                                                     FROM public.rpg_map_under_ways(p.under_at, false, NULL) w)
                                             ELSE jsonb_build_array(jsonb_build_array(p.under_to, 'Go on to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_to) n)),
                                                                    jsonb_build_array(p.under_at, 'Go back to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_at) n))) END END,
                      'mouth', CASE WHEN (p.under_at LIKE 'mouth:%' OR p.under_at LIKE 'cellar:%') AND p.under_to IS NULL THEN true END,
                      -- (storeys step) the floor of a house it stands on, and the stair it can take on its turn
                      'floor', CASE WHEN p.floor <> 0 THEN p.floor END,
                      'stair', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                    THEN public.rpg_stair_ways(p.id) END,
                      'search', CASE WHEN p.under_to IS NULL AND (p.under_at LIKE 'deep-%' OR p.under_at LIKE 'cave-%') THEN true END,
                      'cave', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN CASE WHEN p.floor < 0 THEN (SELECT c.name FROM public.rpg_map_cellar_way(p.pos_x, p.pos_y) c)
                                             WHEN p.floor = 0 THEN (SELECT c.name FROM public.rpg_map_under_cave_at(p.pos_x, p.pos_y) c) END END,
                      'spot', CASE WHEN q.bx >= v_gx0 AND q.bx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.bx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.bx >= v_gx0 AND q.bx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.bx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
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
              -- sx, sy = the square it stands on, counted from 0; bx = that square counted the way this block counts
              -- round the world, for a block that runs past the east or west end
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy,
                                         p.pos_x::bigint - 1 + v_world::bigint * ceil((v_gx0 - p.pos_x::bigint + 1)::numeric / v_world)::bigint AS bx) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id
                AND (v_gm OR p.creature_id IS NULL
                     OR EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                 WHERE o.session_id = s.id AND o.creature_id IS NULL AND o.pos_x IS NOT NULL AND p.pos_x IS NOT NULL
                                   AND public.rpg_square_gap(o.pos_x, o.pos_y, p.pos_x, p.pos_y)
                                       <= coalesce((public.rpg_map_weather_here(o.pos_x - 1, o.pos_y - 1, s.clock)->>'sight')::bigint, public.rpg_setting('sight_squares'))))), '[]'::jsonb),
           'can_join', CASE WHEN NOT v_gm THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb) END)
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  -- (step 14f2; speed step 1) the rivers this read worked out are kept on the saved map's rows (rpg_map_drain_save)
  PERFORM public.rpg_map_drain_save(false);
  -- (speed step 2) and the roads it worked out (rpg_map_road_save)
  PERFORM public.rpg_map_road_save(false);

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', coalesce(v_pname, v_l.name), 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN p_place IS NOT NULL THEN 'p-' || p_place::text
                 WHEN v_slid THEN 's-' || v_x0::text || '-' || v_y0::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves, 'slides', v_slides,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'roads', coalesce(v_roads, '[]'::jsonb), 'road_width', v_rw,
    'crossings', coalesce(v_cross, '[]'::jsonb),
    -- the rivers drawn as lines on the grid (step 14c): [size, x1, y1, x2, y2] in thousandths of a cell from the first cell
    'river_lines', v_rlines,
    'houses', CASE WHEN v_hpend THEN NULL ELSE coalesce(v_houses, '[]'::jsonb) END, 'houses_pending', v_hpend,
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'under', v_under,
    -- (storeys step) the upper floors of the houses on the battle grid: [floor, x, y, part] (part wall, masonry, inner,
    -- floor or stair; floor 1 is the first floor up, floor -1 a cellar)
    'floors', v_floors,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;
UPDATE public.rpg_rules SET body = $rb$The world map is made of the same squares a fight is played on, each 3 feet 8 inches across, and the world is the size of the Earth: 24,901 miles around. The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board. Each cell of a grid shows the ground most of the land inside it holds, so zooming in keeps every coast, mountain chain, wood and climate where it was, only finer.

On a journey everyone takes turns on one clock, the same clock a fight uses. A tick is a sixth of a second, so an hour is 21,600 ticks.

On its turn a piece walks toward any square the game master picks, the whole way in one go: straight, or along the roads (see below). Every square it steps into takes 5 ticks at Speed 10 plus the share of time that square adds, faster or slower by Speed like everything else. The ranges are the same as on a fight board: open land +0% to +10%, forest +20% to +150% with thickets at +400%, mountains +200% to +500%, and so on. A walk longer than about 7 miles counts each 1.2-mile stretch as the average square of its ground. The climate shapes the land: snow and ice, then tundra, toward the poles; pine forest in the cold; desert where it is driest, with seas of sand dunes in its driest parts and salt flats in its lowest ground; grassy plains where it is dry; savanna and scrub where it is warm and a little drier than jungle; jungle where it is hot and wet; swamp in wet lowlands, and bog where those lowlands are cold. Savanna and scrub is +5% to +50%, sand dunes +80% to +150%, salt flats +0% to +15%, bog +50% to +150%. Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, +25% to +75%. One mountain square in twenty is a cliff, climbed with a Climbing roll (see Climbing). Where a stream, river or great river runs through hills or mountains it has cut a gorge. Its walls are cliffs from the water's edge to the rim, climbed square by square like any cliff (see Climbing): 55 degrees in hills, 70 in mountains. A stream's gorge is 8 m deep in hills and 24 m in mountains, a river's 25 m and 75 m, a great river's 40 m and 120 m; brooks cut none. A road crosses on its bridge.
*At Speed 10 a mile of savanna, +27.5% on average, is 1,439 x 5 x 1.275 = 9,174 ticks, about 25 minutes; a mile of sand dunes, +115%, is 15,469 ticks, about 43 minutes; a mile of salt flat, +7.5%, is 7,735 ticks, about 21 minutes; a mile of bog, +100%, is 14,390 ticks, 40 minutes.*
*A river gorge in hills has walls about 16 squares wide each side: each square climbs 1.6 m, Climbing against 3.6, +2,199%, so at Speed 10 it takes 115 ticks, about 5 minutes a wall. In mountains a wall is about 24 squares, 3.1 m a square, Climbing against 6.7, +4,323%: about 15 minutes a wall.*
*A mile is 1,439 squares. At Speed 10 a mile of open land, +5% on average, is 1,439 x 5 x 1.05 = 7,555 ticks, 21 minutes: about 2.9 miles an hour. Zaboo (Speed 5) takes 7,555 x 20 / 15 = 10,073 ticks, 28 minutes. Forest averages +124% with its thickets, so a mile of it takes 45 minutes at Speed 10; mountains average +350%, 1 hour 30 minutes.*

Rivers and lakes run through the land: great rivers 400 m wide and 8 m deep in the middle, rivers 60 m and 3 m, streams 10 m and 0.8 m, brooks 2 m and a quarter of a metre; lakes and ponds cover about 4 in 100 of the land. They sit in the hollows of the land, filled up to the lowest point of their rim, where the water runs on: big lakes in the hollows of the Country grid, lakes in those of the Region grid, ponds in those of the City grid, and a river that reaches one ends at its shore. *Of every 100 square miles of land about 1.5 lie under big lakes, 1.2 under lakes and 1 under ponds: 3.7 in all, as on Earth.* Rivers run faster down a steeper bed: over hills a river's water pulls half again as fast (rapids), over mountains twice as fast, and where it runs over a mountain cliff it falls (a waterfall) at 3 m/s, too rough for anyone to swim. *A river's middle pulls 1.2 m/s, Swimming against 8.6; in hills 1.8 m/s, against 12.9; in mountains 2.4 m/s, too rough to swim. A stream in mountains pulls 1.2 m/s, against 8.6.* A hollow too shallow for a lake is a marsh: its ground is swamp, and a river runs on through it. *A marsh square adds +80% to +200% time like any swamp: 5 × 1.8 = 9 to 5 × 3 = 15 ticks at Speed 10, against 5 to 5.5 on open land.* Rivers wind: at every scale, from the smallest bends a river of its width makes (11 widths long) up to the cells of its own grid, the line swings sideways by about a quarter of that scale, so a river wanders at every zoom and the zoomed-in river lies where the zoomed-out one was drawn. Rivers never cross: a smaller river ends where it meets a bigger one, joining it from either bank, the way a stream runs into a river and a river into a great river. Great rivers run downhill: the water of every Continent cell runs to the neighbour the land lets it reach the sea by, gathering as it goes, and a great river flows wherever the water of about half a million square kilometres (6 Continent cells) has gathered, rising on high ground and ending in the sea or a great lake. A hollow in the land at least 3 deep holds a great lake, full to its rim; it drains on by a river from the lowest point of its rim. *A great lake filling a mountain hollow 170 miles across is up to 150 m deep; the river out of it leaves at the low point of its rim and runs on to the sea.* Rivers run downhill too: inside each Continent cell the water of every Country cell (about 23 km across) runs down to the sea, a great river, or the low crossing where the cell's water goes on to the next cell, and a river flows wherever the water of 20 Country cells, about 11,000 square kilometres, has gathered; smaller rivers join bigger ones like the branches of a tree. *20 Country cells of 538 square kilometres each is about 10,800 square kilometres, a square about 104 km a side: the land one river 60 m wide drains.* Streams and brooks are found the same way, one grid finer each: inside each Country cell a stream flows wherever the water of 82 Region cells, about 300 square kilometres, has gathered, and inside each Region cell a brook flows wherever the water of 470 City cells, about 12 square kilometres, has. *A river's width grows with the square root of the land it drains: a river 60 m wide is 6 times as wide as a stream 10 m wide, so it drains 6 x 6 = 36 times the land, and 11,000 / 36 is about 300 square kilometres (82 Region cells of 3.7 square kilometres each). A brook 2 m wide is a fifth of a stream, so it drains 1/25 of that: about 12 square kilometres (470 City cells of 0.026 square kilometres each).* A river narrower than a cell is drawn as a line through that cell; it fills cells only where it is at least as wide as they are.
*A 60 m river swings about 2 miles either way over its biggest bends, 7 miles long, and about 160 m over its smallest, 660 m long.* A square of water adds time by its depth, the same as on a fight board, and deeper water is drawn darker. Water deeper than 1.2 m is swum, not waded: the walk swims across it, rolling Swimming every few seconds (see Swimming).
*A knee-deep ford square takes 5 × 1.5 = 7.5 base ticks, 8 ticks at Speed 10. Wading across a 10 m stream, 9 squares, takes about 72 ticks, 12 seconds.*

People live in villages, towns and cities, spread over the land the way farming country was in medieval England. In good open land there is a village of 100 to 400 people about every 2 miles, a market town of 500 to 5,000 about every 9, a city of 8,000 to 16,000 about every 110, and a great city of 20,000 to 200,000 about every 330 (London had perhaps 80,000 people c. 1300, Paris about 200,000 in 1328). Forest holds half as many, hills a little more than half; pine forest, jungle, mountains and swamp few; desert and tundra almost none; snow and ice none; and none stand inside a haunt or any other place with ground of its own. A great city needs good land twice over, for its site and for the farms that feed it, so forest has a quarter as many, hills about a third, and rough country almost none; it never stands in the sea. The Continent grid shows the great cities, the Country grid the cities too, the Region grid all four, and closer grids their streets and yards, +0% to +10% time a square like open land. On the battle grid a town or city has a market place at its middle, its main road widened to 16 to 40 m across for 60 to 220 m, and streets running behind the main road with lanes across them, as much street as its households need frontage for: a city of 12,000 people (2,667 households of 4.5) on plots of 1.25 perches needs 2,667 × 6.3 m ÷ 2 = 8.4 km of street, both sides lined; less the roads and the market place already there. The streets lie 50 m apart at the middle and further apart toward the edge (up to 100 m), as the plots near the market filled first. Streets (about 5 m wide) and the market place are paved and walked like a road; lanes are about 2.8 m wide; a street stops at the water, and a church may stand across a street or a lane, which then ends at its walls. Houses stand along the roads, the market place and the streets, one household of 4.5 people to a house, in plots that share both sides of the streets among the households, within the widths medieval surveyors laid out: a village toft 2 to 4 perches (10 to 20 m), a town burgage 1.5 to 2.5 perches, a city plot 1 to 1.5 (a perch is 5 m). A village house is 4 to 5.5 m wide and 2 to 4 bays long (a bay is 4.6 m), one storey under thatch; a town house fills its plot and runs 2 to 3 bays back, two storeys under clay tiles; a city house has two or three, a great city house three or four. A village whose middle only one lane reaches has its street run on through the middle. The District grid shows the same buildings as the battle grids under it. Beside the houses: about half the villages have their own church on the plot at their middle, and six village tofts in ten have a barn behind the house (2 to 3 bays long, 5.5 to 7 m wide); every town and city has its main church at its middle and a parish church for every 1,200 people in a town or 600 in a city (a town of 3,600 people has 3 churches, a city of 12,000 has 20); one town or city plot in ten holds a hall house set along the street across two plots, and six town houses in ten have a back range running back from one side. A parish church lies east to west: a tower 5 to 8 m square and 15 to 30 m high at the west end, a nave 15 to 25 m long (6 to 9 m wide in a village, 12 to 18 m with aisles in a town or city) and a chancel 8 to 14 m long to the east. A great city also has a cathedral in its own close off the streets: a nave 60 to 90 m long, transepts across it, a choir to the east, a tower 40 to 60 m high over the crossing and two at the west front. Roofs are thatch in nine villages in ten; in towns and cities mostly clay tile, with stone slate and some thatch; churches are roofed in lead, stone slate or tile. On the battle grid a building is seen inside. Its outer walls are climbed (see Climbing: a house 2.6 m to its eaves is a 2.6 m sheer wall, Climbing against 10; a church tower 25 m high a 25 m wall), and so are the walls inside a house, one storey high; its doors and floors are walked like the ground. A house whose long side faces its street has a front and a back door opposite each other one bay in from one end (a 3-bay house, 13.8 m long, has them 4.6 m from that end); a house whose gable faces the street has a door in each end beside its passage. A house of 2 bays has a cross wall in its middle, of 3 or more a cross wall one bay in from each end with the hall between, each with a doorway in its middle. A barn has cart doors 2.4 m wide in the middle of both long sides; a church a south and a north door near the west end of its nave; a cathedral a great west door and a door at each end of its transepts. A door is 1.2 m wide. A house of two storeys or more has its stair along the inside of its back wall at the end away from its cross passage, two squares long, and each floor up has the same walls, its doors walls there; the map shows each floor with ▴ ▾ above it, the ground below blurred more the higher the floor. About one house in five with a stair has a cellar under its main part, its stair going on down: one open room, walls all round, shown below the ground floor with the street above it blurred. A church tower has a door in its outer face and its stair in a corner; a great tower (walls 3 m thick) and a watchtower (1.5 m) a door on one side and the stair across from it, where they are wide enough to be hollow; a castle keep (walls 4 m in a fortress, 3.5 m in a castle, 2 m in a tower house) a door facing the gate and its stair in the far corner. A 38 m great tower has 9 floors, a 31 m keep 4.
*A storey is 2.4 to 2.9 m high, so a stair climbs about 2.6 m in its two squares (2.2 m): steep, about 50 degrees.*
*A village of 250 people covers about 12 hectares, a quarter of a mile across. A town of 2,000 is about a third of a mile across, a city of 12,000 about two thirds of a mile. A great city of 100,000, at 230 people a hectare (a bigger city is more crowded), covers 435 hectares, about a mile and a half across.*

Roads join the places people live, from one to the next, and wander on the way: a road leaves each place straight and bends about the line between them, its biggest bends (up to 3.6 miles long) swinging a highway sideways by 6 in 100 of their length, a road 9 and a lane 12, and every bend half as long swinging less for its length, so a road is smoothest close up and the zoomed-in road lies where the zoomed-out one was drawn. The houses of a village, town or city line the road where it truly runs.
*A lane between villages 1.8 miles apart swings about 200 m either way; a highway between towns 7 miles apart about 350 m, 600 m at most.* A highway 6.5 m wide (about 6 squares, the width of the main Roman roads) runs from each city to the cities around it, by way of the market towns between; a road 4.9 m wide (about 4 squares, room for two carts to pass) joins each town to the towns around it; and a lane 2.4 m wide (about 2 squares, one cart) runs from each village toward its market town, as far as the next place where people live. Roads cross lakes on a causeway and rivers on a bridge or through a ford, but never the sea, and keep out of any place with rough ground of its own, like the Old Forest; through an open place they run on its own ground. Every highway bridges every river it meets; a road fords about one river or stream in three and a lane two in three, one call a stretch, so a lane that fords a river fords it at every crossing; a great river is always bridged and a brook needs only a plank. A ford is knee-deep (0.5 m, +50% a square) from bank to bank and 9 m along the river; a bridge is road over the water. Rivers and streams have planned fords off the roads too, about one in twelve City cells they run through, shown from the City grid down (streams from the District grid): a walk sent through one wades where it would swim. A square of road adds +0% to +10% time whatever ground it crosses, except a mountain road, which keeps three fifths of the time of mountains, +80% to +260%; snow and ice stay snow and ice. The Country grid shows the highways, the closer grids all three.
*At Speed 10 a mile of road takes 21 minutes, like open land, and a mile of mountain road 54 minutes instead of 1 hour 30.*

A walk keeps to the roads where they are quicker by its count: every step off a road counts as 5/3 of a step on one (walking off a path takes that much longer, Tobler 1993), and the walk takes the way with the fewest. It plans its way up to about 14 miles ahead; when the end lies farther and the roads lead on, it stops where its plan ends and can carry on from there next turn.
*A town 8 miles away across forest is 6 hours straight at Speed 10; by a road 10 miles long, 3 hours 30.*

Nobody walks into the sea or into water too rough to swim, and a walk never ends in deep water. A walk that reaches either stops on the last dry square. A walk also stops one square short of anyone standing in its way.

A piece walks at most 8 hours a day, then camps 16 hours where it stands. If the day runs out on the way, it camps there and can carry on next turn. A piece can also camp on its turn instead of walking, which starts its walking day fresh.
*At Speed 10, 8 hours of open land is about 23 miles.*

Creatures live in their haunts. For every full hour a piece walks inside a haunt, the site rolls a d100: on 15 or less a creature of that haunt appears 10 squares (37 feet) away, the walk stops and the fight is on, on that ground.
*Over 8 hours in a haunt that is a fight on about 3 days in 4: the chance of no creature all day is 0.85 multiplied by itself 8 times, 0.27.*

While a creature still in the fight stands within 164 squares (600 feet, a longbow shot), a piece moves on the fight board, a turn at a time, instead of walking the map.

Landmarks stand out on the land and are steered by from far off: lone peaks, castles, ruins, towers, stone circles, standing stones, boulders and cairns, as big as real ones are. The World grid shows the greatest few, a great peak rising 15,000 to 20,000 feet or the ruins of a city miles across; every grid shows its own and all those of the grids above it: the Continent grid peaks and fortresses, the Country grid mountains, castles and great towers, the Region grid hills, tower houses, ruined chapels, watchtowers and stone circles, the City grid crags, mottes, ruined crofts, beacons and great standing stones, the District grid boulders, broken walls, standing stones and cairns. Peaks stand on mountains and hills, and a great peak sometimes alone on open land, as the great volcanoes do; castles on farmland and hills; ruins anywhere dry; none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own. On the battle grid they stand as they are: a castle is a keep inside a curtain wall with one gate, a ruin is the broken walls of its rooms, a stone circle a ring of stones about 4 m apart; their walls, towers, stones and boulders are climbed like the wall of a house (see Climbing), a cairn or the side of a motte like a slope of rock, and a walk goes round them. A lone peak is the mountain itself.
*A castle keep 100 feet tall is made out from about 13 miles. Its top shows over the horizon from 12.3 miles (the square root of 2 × the radius of the world × its 30.5 m), on top of the 2.7 miles of a person's own horizon, 15 miles; but the eye makes out only what spans 5 minutes of arc, 30.5 m ÷ 0.00145 = 21 km, 13 miles, the nearer of the two. A standing stone 2 m tall is made out from about 4,500 feet, a peak rising 13,000 feet from about 140 miles. Karen (Climbing 7) needs 59 to get up the wall of a tower house, 5.4 m and sheer; a slip drops her 5.4 m for 6 damage.*

Places to go into are smaller: caves, mines, shrines, camps and huts, rolled where no landmark stands. The Region grid shows great caves, mine workings and war camps, the City grid caves, mines, shrines, camps and huts, the District grid hollows, wayside shrines, campsites and huts. Caves and mines lie in mountains and hills, camps in woods and on open land, shrines and huts on any dry ground. On the battle grid each has its way in: a hut or a shrine its door, a cave or a mine its mouth, a war camp its gate. Their walls, rock, palisades and tents are climbed like the wall of a house, a spoil heap like a slope of rock; the floor inside is walked like the ground.
*A hut 6 m across and 4 m tall is 5 squares wide: a ring of wall to the eaves, 2.4 m and sheer (Climbing against 10), round 5 squares of floor with the hearth in the middle, and one square of door.*

Under the ground runs a world of its own. Cave country, 3 in 10 of the land (twice Earth's share of cave rock), holds chambers 100 to 9,800 feet down, about one every 2.4 miles, joined into systems hundreds of miles long. Below it all lie the Deeps, 13,000 to 26,000 feet below the sea: a great hall about every 86 miles, most of them joined into one network that runs round the world and under the seas. Caves and mines lead in: a great cave runs up to 3 miles into the hill, mine workings go down a shaft as deep as 13,000 feet; most great caves and some caves and mines break into cave country, and a few reach the Deeps. The Underground switch on the map shows what lies under a grid; your group sees the passage of a cave or mine once it has found it.
*A chamber's depth is rolled on a doubling scale between 100 and 9,800 feet, as many shallow as deep: a roll of 50 puts it about 960 feet down.*

To go under the ground, a piece stands at a cave or a mine and goes in. Under the ground it walks one passage at a time to where the passage leads: on through the Deeps at a good pace (+25% time), along cave passages by crawling and scrambling (+250%: cavers make about half a mile an hour), through the galleries of a mine (+50%), squeezing through where a cave or mine breaks into cave country or the Deeps (+400%), and up or down a shaft at 1,000 feet an hour. The walking day is the same as on the surface: 8 hours, then 16 to camp, in the passage if need be. From below, the ways up into caves and mines are hidden until someone searches the chamber or great hall (1 hour) or has walked them. A piece comes up only at the mouth of a cave or a mine.
*At Speed 10 the 2,440-foot passage of Storm Grotto takes about 32 minutes, and the 1.26-mile squeeze from its far end into cave country about 2 hours 6 minutes.*

Under the ground there is a battle grid too, square for square like the one on the surface. A passage winds, widens and narrows as it goes: a passage of the Deeps is 50 to 300 feet wide, a cave passage 5 to 26 feet, a mine gallery 7 to 16 feet, a squeeze 2 to 5 feet (never less than a square). Chambers of cave country are 40 to 400 feet across, the great halls of the Deeps 1,000 to 4,900 feet. Everything else is solid rock: no way in. Floors cost time like ground on the surface: the Deeps +10% to +40%, cave floor +100% to +357% with fallen rock (+400%) on one square in eight, mine floor +20% to +80%, a squeeze +300% to +500%; a pool is waded by its depth, a column of stone is no way through, a shaft is climbed. Creatures are met under the ground the same way as in their haunts on the surface: every hour walked in a passage where a creature lives, a roll of 15 or less meets one, and the fight is on, on the battle grid under the ground.
*The average square of a floor is what a walk under the ground takes: cave floor is 0.875 x (100 + 357) / 2 + 0.125 x 400 = 250%, so at Speed 10 a square of it takes 5 x 3.5 = 17.5 ticks, about 3 seconds.*

The map shows what your group has found: everything within 2.7 miles each way of where any of you walked, the distance to the horizon for a person's eyes. The rest stays dark until someone goes there or knows the place. A landmark shows from as far off as it can be made out, even over ground not found yet.
*A 20-mile walk shows a strip about 25 miles long and 5.4 miles wide.*

Weather comes and goes over every 14-mile patch of land, worked out every 3 hours of the journey. It adds time to every square you walk, on top of the ground: fog and rain +10%, a thunderstorm +25%, snow +30%, a dust storm +50%, a blizzard +100%. It slows swimming and climbing a cliff too, on a walk and in a fight. Weather also cuts how far you see, so less of the map opens up as you walk: rain about 1.9 miles each way, a thunderstorm or snow about half a mile, fog about a third of a mile, a blizzard a quarter mile. Clear or cloudy weather lets you see the full 2.7 miles.
*A 20-mile walk in fog shows a strip about 20.6 miles long and 0.62 miles wide, instead of 25.4 by 5.4 in clear weather.*
*Open land at +5% takes 5 × 1.05 = 5.25 ticks a square at Speed 10. In snow it is +35%: 5 × 1.35 = 6.75 ticks, so a 20-mile walk of 6 h 40 min takes about 8 h 34 min.*
In a fight outdoors the weather counts too (not under the ground or inside a building). Every step takes the weather's extra time on top of the ground's, as on a walk, swimming and climbing included. Rain, a thunderstorm, snow or a blizzard soak what would burn, so a square set alight does not catch. A dust storm keeps a fire burning a round longer, 4 rounds instead of 3. A thunderstorm, a blizzard or a dust storm blows shots off their mark: a blow from 2 squares away or more that lands is carried wide when its die is in the lower half of the dice that land, the same as half cover.
*In a blizzard a plain square at +5% takes 5 × 2.05 = 10.25 ticks at Speed 10 instead of 5.25, so a turn's 20 ticks of moving cover 1 such square instead of 3. A longbow needing 50 in a thunderstorm lands on 50 to 100, but 50 to 74 are carried wide; only 75 or more go on to the Block gate.*$rb$, updated_at = now() WHERE key = 'world_map';

