INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
('126794dd-25ff-47d2-a436-724499733365', 'map_beach_width', 30, 'Beach: squares of low coast next to the sea that are beach (about 33 m; most beaches are 20 to 100 m)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_beach_penalty', 20, 'Beach: least percent of time a square adds to cross it (firm wet sand by the water)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_beach_penalty_high', 60, 'Beach: most percent of time a square adds to cross it (soft dry sand; walking on sand costs 1.6 to 2.1 times firm ground, Lejeune et al. 1998)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_seacliff_height_hills', 20, 'Sea cliff: metres high where hills meet the sea'),
('126794dd-25ff-47d2-a436-724499733365', 'map_seacliff_height_mountains', 60, 'Sea cliff: metres high where mountains meet the sea'),
('126794dd-25ff-47d2-a436-724499733365', 'map_seacliff_angle_hills', 70, 'Sea cliff: degrees steep in hills'),
('126794dd-25ff-47d2-a436-724499733365', 'map_seacliff_angle_mountains', 80, 'Sea cliff: degrees steep in mountains')
ON CONFLICT (agency_id, key) DO NOTHING;
CREATE OR REPLACE FUNCTION public.rpg_map_coast(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, d double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How far each land cell of a block stands from the sea, in squares, on the District grid and the battle grid (more
-- terrain step 3a, Peter 2026-10-10: coastal cliffs and beaches), the one home of it: rpg_map_cells_make lays the
-- beaches by it, rpg_map_cliffs the sea cliffs. Only cells within the farthest of those reaches (map_beach_width,
-- and each sea cliff's width) come back; a block with no sea in the City cells round it reads nothing more
-- (rpg_map_kinds), so inland the cost is one look at the saved map. The sea is where the land stands below the sea
-- (rpg_map_heights, as rpg_map_nature makes it); the distance is worked out over the block and a margin round it by two
-- sweeps (a chamfer distance: 1 a cell across, 1.41 corner to corner), so it does not depend on the block that asks.
DECLARE
  v_cell double precision; v_c5 double precision; v_sea double precision; v_reach double precision; v_b integer;
  v_w integer; v_h integer; v_d double precision[]; v_i integer; v_j integer; v_k integer; v_n double precision;
  v_x integer; v_y integer;
BEGIN
  IF p_level < 6 THEN RETURN; END IF;
  SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  SELECT l.cell INTO v_c5 FROM public.rpg_map_ladder() l WHERE l.level = 5;
  SELECT max(s.value) FILTER (WHERE s.key = 'map_sea_level'),
         greatest(max(s.value) FILTER (WHERE s.key = 'map_beach_width'),
                  max(s.value) FILTER (WHERE s.key = 'map_seacliff_height_hills') / tan(radians(max(s.value) FILTER (WHERE s.key = 'map_seacliff_angle_hills'))) / max(s.value) FILTER (WHERE s.key = 'map_square_m'),
                  max(s.value) FILTER (WHERE s.key = 'map_seacliff_height_mountains') / tan(radians(max(s.value) FILTER (WHERE s.key = 'map_seacliff_angle_mountains'))) / max(s.value) FILTER (WHERE s.key = 'map_square_m'))
    INTO v_sea, v_reach
    FROM public.rpg_settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND s.key IN ('map_sea_level', 'map_beach_width', 'map_square_m', 'map_seacliff_height_hills', 'map_seacliff_angle_hills', 'map_seacliff_height_mountains', 'map_seacliff_angle_mountains');
  -- no sea in the City cells under the block and round it: nothing within reach
  IF NOT EXISTS (SELECT 1 FROM public.rpg_map_kinds(5, floor(p_x0 * v_cell / v_c5)::integer - 1, greatest(floor(p_y0 * v_cell / v_c5)::integer - 1, 0),
                                                    floor((p_x0 + p_cols - 1) * v_cell / v_c5)::integer - floor(p_x0 * v_cell / v_c5)::integer + 3,
                                                    floor((p_y0 + p_rows - 1) * v_cell / v_c5)::integer - floor(p_y0 * v_cell / v_c5)::integer + 3) k
                  WHERE k.kind = 'sea') THEN
    RETURN;
  END IF;
  v_b := ceil(v_reach / v_cell)::integer + 1;
  v_w := p_cols + 2 * v_b; v_h := p_rows + 2 * v_b;
  v_d := array_fill(1e9::double precision, ARRAY[v_w * v_h]);
  FOR v_x, v_y IN SELECT h.x, h.y FROM public.rpg_map_heights(p_level, p_x0 - v_b, p_y0 - v_b, v_w, v_h) h WHERE h.height < v_sea LOOP
    v_d[(v_y - (p_y0 - v_b)) * v_w + (v_x - (p_x0 - v_b)) + 1] := 0;
  END LOOP;
  -- forward sweep, then back
  FOR v_j IN 0 .. v_h - 1 LOOP
    FOR v_i IN 0 .. v_w - 1 LOOP
      v_k := v_j * v_w + v_i + 1; v_n := v_d[v_k];
      IF v_i > 0 THEN v_n := least(v_n, v_d[v_k - 1] + 1); END IF;
      IF v_j > 0 THEN
        v_n := least(v_n, v_d[v_k - v_w] + 1);
        IF v_i > 0 THEN v_n := least(v_n, v_d[v_k - v_w - 1] + 1.414); END IF;
        IF v_i < v_w - 1 THEN v_n := least(v_n, v_d[v_k - v_w + 1] + 1.414); END IF;
      END IF;
      v_d[v_k] := v_n;
    END LOOP;
  END LOOP;
  FOR v_j IN REVERSE v_h - 1 .. 0 LOOP
    FOR v_i IN REVERSE v_w - 1 .. 0 LOOP
      v_k := v_j * v_w + v_i + 1; v_n := v_d[v_k];
      IF v_i < v_w - 1 THEN v_n := least(v_n, v_d[v_k + 1] + 1); END IF;
      IF v_j < v_h - 1 THEN
        v_n := least(v_n, v_d[v_k + v_w] + 1);
        IF v_i < v_w - 1 THEN v_n := least(v_n, v_d[v_k + v_w + 1] + 1.414); END IF;
        IF v_i > 0 THEN v_n := least(v_n, v_d[v_k + v_w - 1] + 1.414); END IF;
      END IF;
      v_d[v_k] := v_n;
    END LOOP;
  END LOOP;
  RETURN QUERY
  SELECT p_x0 + i, p_y0 + j, v_d[(j + v_b) * v_w + (i + v_b) + 1] * v_cell
    FROM generate_series(0, p_cols - 1) AS i CROSS JOIN generate_series(0, p_rows - 1) AS j
   WHERE v_d[(j + v_b) * v_w + (i + v_b) + 1] > 0 AND v_d[(j + v_b) * v_w + (i + v_b) + 1] * v_cell <= v_reach;
END;
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
--  * (more terrain step 3a) a sea cliff: hills or mountains where they meet the sea (rpg_map_coast), 20 m at 70 degrees
--    in hills and 60 m at 80 degrees in mountains, the face as wide as its height over the tangent of its angle.
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
     -- (more terrain step 3a) sea cliffs: hills or mountains within a cliff's width of the sea (rpg_map_coast) are its face,
     -- map_seacliff_height_<ground> high at map_seacliff_angle_<ground>: hills 20 m at 70 degrees, 6.5 squares; mountains
     -- 60 m at 80 degrees, 9.5 squares
     sw AS (SELECT (SELECT st2.value FROM public.rpg_settings st2 WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_seacliff_angle_hills')::double precision AS ah,
                   (SELECT st2.value FROM public.rpg_settings st2 WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_seacliff_angle_mountains')::double precision AS am,
                   (SELECT st2.value FROM public.rpg_settings st2 WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_seacliff_height_hills')::double precision AS hh,
                   (SELECT st2.value FROM public.rpg_settings st2 WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_seacliff_height_mountains')::double precision AS hm,
                   (SELECT st2.value FROM public.rpg_settings st2 WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_square_m')::double precision AS sq),
     sc AS MATERIALIZED (SELECT c.x, c.y, CASE WHEN c.d <= sw.hm / tan(radians(sw.am)) / sw.sq THEN sw.am END AS am,
                                CASE WHEN c.d <= sw.hh / tan(radians(sw.ah)) / sw.sq THEN sw.ah END AS ah
                           FROM sw CROSS JOIN LATERAL public.rpg_map_coast(p_level, p_x0, p_y0, p_cols, p_rows) c WHERE p_level = 7),
     al AS (SELECT gm.x, gm.y FROM gm UNION SELECT gh.x, gh.y FROM gh UNION SELECT mc.x, mc.y FROM mc
            UNION SELECT sc.x, sc.y FROM sc WHERE sc.am IS NOT NULL OR sc.ah IS NOT NULL)
SELECT al.x, al.y, greatest(gm.angle, mc.angle, sc.am), greatest(gh.angle, sc.ah),
       CASE WHEN gm.angle >= coalesce(mc.angle, 0) THEN gm.k ELSE gh.k END
  FROM al LEFT JOIN gm ON gm.x = al.x AND gm.y = al.y LEFT JOIN gh ON gh.x = al.x AND gh.y = al.y
  LEFT JOIN mc ON mc.x = al.x AND mc.y = al.y
  LEFT JOIN sc ON sc.x = al.x AND sc.y = al.y;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_cells_make(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of any block of cells of any grid of the world map, worked out (step 13 moved it here from rpg_map_cells,
-- which reads the saved map first and comes here for what is not saved). The one home of how what a cell is is worked
-- out; a single square under a piece is the same call at the battle grid, 1 by 1.
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
--              yards. Only the City grid and finer: a coarser grid marks them instead (rpg_map_view_block). On the
--              battle grid (step 3) a square of it that a road, the market place, a street or a lane runs over is
--              road ground instead (below), the rest its yards.
--   road       the battle grid only: a highway, road or lane runs over the square (rpg_map_road_cells; step 8b), or
--              inside a town or city its market place, a street or a lane (rpg_map_street_cells; step 3), the
--   pass       middle of the square within half the width of the road from its line: road, or pass where the ground under
--              it is mountains (a road over a pass keeps its climb). A road over snow and ice is the snow and ice; where
--              a road meets a river or a lake it crosses it: by a bridge (road, ahead of the water) or, where the
--              stretch fords that river (step 11; rpg_map_ford_cells), through the water, which is knee-deep there
--              (water, waded); the sea stops it. A street or a lane stops at the water (only the roads bridge it).
--              Coarser grids draw roads as lines instead.
--   swamp      (step 14f4) dry land in a marsh, a hollow too shallow for a lake (rpg_map_water), unless desert, sand dunes
--              or salt flats (a dry hollow) or snow and ice; bog where the land round it is cold (pine forest, tundra or
--              bog; more terrain step 1); in desert or sand dunes an oasis (step 2b: a shallow desert hollow is where
--              the ground water comes up, a spring with palms and grass round it; in salt flats it stays salt, a dry lake bed).
--   beach      (more terrain step 3a) the District grid and the battle grid: low coast within map_beach_width (30
--              squares, about 33 m) of the sea (rpg_map_coast), of open, wooded or dry ground; hills and mountains meet
--              the sea in cliffs instead (rpg_map_cliffs), marsh and deltas in mud.
--   delta      (more terrain step 2b) low ground at a river's mouth: on the Country grid, a land cell a great river or a
--              river runs through with the sea beside it is a mouth; a great river's delta covers its mouth cell and the
--              cells round it (about 70 km; Earth's great deltas run 50 to 300 km), a river's its mouth cell; inside that,
--              every cell no higher than map_delta_height above the sea is delta, whatever its ground but hills, mountains or
--              snow and ice (the Nile's delta is green in the desert). A finer
--              grid keeps it inside the Country cells that are delta (rpg_map_kinds), by its own heights.
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
     g AS MATERIALIZED (
       -- The ground the land makes in each cell (rpg_map_ground_of; step 9 and 14f1): what most of the grid under it holds.
       SELECT n.x AS gx, n.y AS gy, n.kind <> 'sea' AS dry, lad.cell, lad.world, n.kind
         FROM lad CROSS JOIN public.rpg_map_ground_of(p_level, p_x0, p_y0, p_cols, p_rows) n),
     wt AS MATERIALIZED (
       -- rivers and lakes on the block (rpg_map_water)
       SELECT w.x, w.y, w.depth, w.marsh FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w),
     -- (more terrain step 2b) river deltas. On the Country grid, read two cells past the block so a cell's answer never
     -- depends on the block that asks: a river's mouth is a land Country cell a great river's or a river's line runs
     -- through (rpg_map_water: line 2 or 3) with the sea beside it
     db AS (SELECT p_x0 - 2 AS x0, p_y0 - 2 AS y0, p_cols + 4 AS nc, p_rows + 4 AS nr),
     g3 AS MATERIALIZED (SELECT n.x, n.y, n.kind FROM db CROSS JOIN LATERAL public.rpg_map_ground_of(3, db.x0, db.y0, db.nc, db.nr) n WHERE p_level = 3),
     w3 AS MATERIALIZED (SELECT w.x, w.y, w.line FROM db CROSS JOIN LATERAL public.rpg_map_water(3, db.x0, db.y0, db.nc, db.nr) w
                          WHERE p_level = 3 AND w.line IN (2, 3) AND EXISTS (SELECT 1 FROM g3 WHERE g3.kind = 'sea')),
     mo AS MATERIALIZED (SELECT w3.x, w3.y, w3.line AS k FROM w3 JOIN g3 me ON me.x = w3.x AND me.y = w3.y AND me.kind <> 'sea'
                          WHERE EXISTS (SELECT 1 FROM g3 s WHERE s.kind = 'sea' AND abs(s.x - w3.x) <= 1 AND abs(s.y - w3.y) <= 1)),
     -- finer grids: the Country cells under the block that are delta (rpg_map_kinds)
     an AS MATERIALIZED (
       SELECT k.x, k.y FROM lad CROSS JOIN (SELECT l.cell::double precision AS c3 FROM public.rpg_map_ladder() l WHERE l.level = 3) l3
        CROSS JOIN LATERAL public.rpg_map_kinds(3, floor(p_x0 * lad.cell / l3.c3)::integer, floor(p_y0 * lad.cell / l3.c3)::integer,
                                                floor((p_x0 + p_cols - 1) * lad.cell / l3.c3)::integer - floor(p_x0 * lad.cell / l3.c3)::integer + 1,
                                                floor((p_y0 + p_rows - 1) * lad.cell / l3.c3)::integer - floor(p_y0 * lad.cell / l3.c3)::integer + 1) k
        WHERE p_level >= 4 AND k.kind = 'delta'),
     -- (more terrain step 3a) beaches: on the District grid and the battle grid, how far each land cell is from the sea
     -- (rpg_map_coast)
     cs AS MATERIALIZED (SELECT c.x, c.y, c.d FROM public.rpg_map_coast(p_level, p_x0, p_y0, p_cols, p_rows) c WHERE p_level >= 6
                            AND c.d <= (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_beach_width')),
     dl AS MATERIALIZED (
       -- a cell of the delta: no higher than map_delta_height above the sea, and on the Country grid within a great
       -- river's mouth cell or one round it, or a river's mouth cell; on a finer grid inside a Country cell that is delta
       SELECT h.x, h.y
         FROM lad CROSS JOIN (SELECT l.cell::double precision AS c3 FROM public.rpg_map_ladder() l WHERE l.level = 3) l3
        CROSS JOIN (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                           (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_delta_height')::double precision AS top) dc
        CROSS JOIN LATERAL public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h
        WHERE (EXISTS (SELECT 1 FROM mo) OR EXISTS (SELECT 1 FROM an))
          AND h.height - dc.sea BETWEEN 0 AND dc.top
          AND (EXISTS (SELECT 1 FROM mo WHERE abs(mo.x - h.x) <= CASE WHEN mo.k = 2 THEN 1 ELSE 0 END AND abs(mo.y - h.y) <= CASE WHEN mo.k = 2 THEN 1 ELSE 0 END)
               OR EXISTS (SELECT 1 FROM an WHERE an.x = floor((h.x + 0.5) * lad.cell / l3.c3)::integer AND an.y = floor((h.y + 0.5) * lad.cell / l3.c3)::integer))),
     tc AS MATERIALIZED (
       -- the cells inside a village, town or city (rpg_map_town_cells): the City grid and finer
       SELECT t.x, t.y FROM public.rpg_map_town_cells(p_level, p_x0, p_y0, p_cols, p_rows) t WHERE p_level >= 5),
     rd AS MATERIALIZED (
       -- the squares a road runs over (rpg_map_road_cells): the battle grid only
       SELECT r.x, r.y FROM public.rpg_map_road_cells(p_level, p_x0, p_y0, p_cols, p_rows) r WHERE p_level = 7),
     st AS MATERIALIZED (
       -- the squares a market place, street or lane inside a town or city runs over (rpg_map_street_cells; step 3)
       SELECT s.x, s.y FROM public.rpg_map_street_cells(p_level, p_x0, p_y0, p_cols, p_rows) s WHERE p_level = 7),
     fd AS MATERIALIZED (
       -- the squares where a road fords the water (rpg_map_ford_cells; step 11): only where a road runs over water
       SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(p_level, p_x0, p_y0, p_cols, p_rows) f
        WHERE p_level = 7 AND f.kind = 'ford' AND EXISTS (SELECT 1 FROM rd JOIN wt ON wt.x = rd.x AND wt.y = rd.y WHERE wt.depth > 0)),
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
            WHEN rd.x IS NOT NULL AND wt.depth > 0 AND fd.x IS NULL THEN 'road'
            WHEN wt.depth >= cfg.swim THEN 'deep'
            WHEN wt.depth > 0 THEN 'water'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            WHEN tc.x IS NOT NULL AND rd.x IS NULL AND st.x IS NULL THEN 'town'
            WHEN (rd.x IS NOT NULL OR st.x IS NOT NULL) AND g.kind = 'mountains' THEN 'pass'
            WHEN (rd.x IS NOT NULL OR st.x IS NOT NULL) AND (g.kind <> 'ice' OR tc.x IS NOT NULL) THEN 'road'
            WHEN tc.x IS NOT NULL THEN 'town'
            WHEN dl.x IS NOT NULL AND g.kind IN ('land', 'plains', 'savanna', 'forest', 'pine', 'jungle', 'tundra', 'swamp', 'bog', 'desert', 'dunes', 'salt') THEN 'delta'
            WHEN cs.x IS NOT NULL AND g.kind IN ('land', 'plains', 'savanna', 'forest', 'pine', 'jungle', 'tundra', 'desert', 'dunes', 'salt') THEN 'beach'
            WHEN wt.marsh AND g.kind IN ('desert', 'dunes') THEN 'oasis'
            WHEN wt.marsh AND g.kind NOT IN ('desert', 'dunes', 'salt', 'ice') THEN CASE WHEN g.kind IN ('pine', 'tundra', 'bog') THEN 'bog' ELSE 'swamp' END
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN tc ON tc.x = g.gx AND tc.y = g.gy
  LEFT JOIN rd ON rd.x = g.gx AND rd.y = g.gy
  LEFT JOIN st ON st.x = g.gx AND st.y = g.gy
  LEFT JOIN fd ON fd.x = g.gx AND fd.y = g.gy
  LEFT JOIN dl ON dl.x = g.gx AND dl.y = g.gy
  LEFT JOIN cs ON cs.x = g.gx AND cs.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, wt.marsh, cfg.swim, tc.x, rd.x, st.x, fd.x, dl.x, cs.x
 ORDER BY g.gy, g.gx;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; 2026-10-10 more
-- terrain, step 1: savanna and scrub, sand dunes, salt flats, bog; step 2b: oasis, river delta (both laid by
-- rpg_map_cells_make, over the ground the land makes); step 3a: beach (the same, District and battle grids); rivers and
-- lakes; villages, towns and cities, step 8; roads, step 8b: a road, and a road over mountains, whose range is that of
-- mountains kept to map_road_keep, rpg_map_band; the floors under the ground, step 12d3: of the Deeps +10% to +40%, of a
-- cave +100% to +357% with rubble +400% for one square in eight, of a mine +20% to +80%, a squeeze +300% to +500%, so
-- their average squares are the times a walk under the ground takes, 25, 250, 50 and 400), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
-- detail; the page reads the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent
-- of time a square of it adds to cross it (the most is the same key with _high; rpg_map_band; water goes by its depth,
-- rpg_map_wade_pct; deep water is swum, step 7b; the sea = no walking in), and whether it is forest (it has trees: it burns and
-- hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', 'map_land_penalty', false),
               (3, 'plains', 'Grassy plains', 'g', 'map_plains_penalty', false),
               (3.5, 'savanna', 'Savanna and scrub', 'v', 'map_savanna_penalty', false),
               (3.7, 'beach', 'Beach', 'y', 'map_beach_penalty', false),
               (4, 'forest', 'Forest', 't', 'map_forest_penalty', true),
               (5, 'pine', 'Pine forest', 'p', 'map_pine_penalty', true),
               (6, 'jungle', 'Jungle', 'j', 'map_jungle_penalty', true),
               (7, 'hills', 'Hills', 'h', 'map_hills_penalty', false),
               (8, 'mountains', 'Mountains', 'm', 'map_mountain_penalty', false),
               (9, 'desert', 'Desert', 'd', 'map_desert_penalty', false),
               (9.3, 'dunes', 'Sand dunes', 'e', 'map_dunes_penalty', false),
               (9.6, 'salt', 'Salt flats', 'f', 'map_salt_penalty', false),
               (9.8, 'oasis', 'Oasis', 'o', 'map_oasis_penalty', false),
               (10, 'tundra', 'Tundra', 'u', 'map_tundra_penalty', false),
               (11, 'ice', 'Snow and ice', 'i', 'map_ice_penalty', false),
               (12, 'swamp', 'Swamp', 's', 'map_swamp_penalty', false),
               (12.5, 'bog', 'Bog', 'b', 'map_bog_penalty', false),
               (12.7, 'delta', 'River delta', 'l', 'map_delta_penalty', false),
               (13, 'water', 'Shallow water', 'w', NULL, false),
               (14, 'deep', 'Deep water', 'k', NULL, false),
               (15, 'town', 'Village, town or city', 'n', 'map_town_penalty', false),
               (16, 'road', 'Road', 'r', 'map_road_penalty', false),
               (17, 'pass', 'Mountain road', 'a', NULL, false),
               (18, 'under_deep', 'Floor of the Deeps', 'D', 'map_under_deep_penalty', false),
               (19, 'under_cave', 'Cave floor', 'C', 'map_under_cave_penalty', false),
               (20, 'under_mine', 'Mine floor', 'M', 'map_under_mine_penalty', false),
               (21, 'under_squeeze', 'Squeeze', 'Q', 'map_under_squeeze_penalty', false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_landmark_kinds()
 RETURNS TABLE(rank integer, kind text, icon text, words text, weight double precision, h_low double precision, h_high double precision, w_low double precision, w_high double precision, pattern text, ends text[], grounds jsonb)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The landmarks of the world map (step 12b; Peter 2026-10-03 17:28: choice landmarks at every layer, few on the world,
-- more each level down; 2026-10-06: things seen and steered by from far: lone peaks, castles, ruins, towers, standing
-- stones), the one home of what each can be. rank = the coarsest grid that shows it (1 the World grid to 6 the District
-- grid; a landmark shows on every grid from its rank down); kind and icon = what it is and its map symbol (rpg_map_icons);
-- words = what the map calls it; weight = its share of the landmarks of its rank (the weights of a rank add up to 1);
-- h_low, h_high = how tall it stands, in metres (a peak: how far it rises above the land round it, its prominence);
-- w_low, w_high = how far across it is, in metres; both rolled on a doubling scale between them, as many small as big;
-- pattern = its name, {A} a word of the uplands and {B} one of ends; grounds = how readily it stands on each kind of
-- ground of the cell of its rank (1 as readily as anywhere, 0 or missing never). Worked out when asked, never stored.
-- Each rank is about one grid bigger than the next: a landmark of a rank is about as big as the cell of the
-- grid two levels finer, and is seen about as far as a cell of its own grid or more (rpg_map_landmark_sight).
-- The sizes are of real ones: a lone great peak, Kilimanjaro, rises 5,885 m on a base 60 km across, Mount Rainier
-- 4,026 m, Etna 3,357 m, Ben Nevis 1,345 m, Glastonbury Tor 145 m; a ruined city, Angkor, spreads 8 km, its
-- temple 65 m tall; a great fortress, the walled Cite of Carcassonne, is about 600 m across, Krak des Chevaliers
-- 210 m; a castle keep stands 25 to 35 m (Rochester 34 m) in a bailey 80 to 250 m across; a tower house 15 to 25 m;
-- a motte 8 to 15 m on a base 30 to 60 m (motte-and-bailey castles, 11th to 12th century); a great tower, the
-- Roman lighthouse of A Coruna, 55 m; a watchtower 15 to 30 m; a fire beacon 6 to 12 m; a stone circle 30 to 110 m
-- across of stones 2 to 5 m (Castlerigg 30 m, Long Meg 100 m); a great standing stone 4 to 8 m (Rudston 7.6 m);
-- a standing stone 1.2 to 3.5 m; a cairn 1 to 3 m.
-- Peaks stand on mountains (and hills, from the Region grid down); a great peak or a peak of the Continent grid may also
-- rise alone from open land, as the great volcanoes do (Kilimanjaro from savanna, Fuji, Ararat, Elbrus), less readily;
-- castles on good farmland as villages do, readily on hills; ruins anywhere dry, most of all in forest, jungle and
-- desert where nobody rebuilt; towers and stone circles on open land and uplands (most British stone circles stand on
-- moor and upland); cairns on hills, mountains and tundra.
-- More terrain step 1 (2026-10-10): savanna and scrub weighs as open land (the ground it was), bog as swamp, sand
-- dunes half of desert (ruins in full: cities buried in sand), salt flats a fifth of desert.
-- Step 2b: an oasis and a river delta weigh as open land.
-- Step 3a: a beach weighs half as open land.
-- Nothing stands in the sea, in water, on snow and ice, on a road or a street, or inside a place with ground of its own.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (1, 'peak',   'peak',   'Great peak',      0.6,  4500, 6000, 30000, 60000, '{A}{B}',            ARRAY['horn', 'peak', 'spire'],           '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2, "savanna": 0.3, "dunes": 0.15, "salt": 0.06, "oasis": 0.3, "delta": 0.3, "beach": 0.15}'),
    (1, 'ruins',  'ruins',  'Ruined city',     0.4,    40,   70,  3000,  9000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (2, 'peak',   'peak',   'Peak',            0.45, 2500, 4500, 15000, 40000, '{A}{B}',            ARRAY['horn', 'pike', 'fell'],            '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2, "savanna": 0.3, "dunes": 0.15, "salt": 0.06, "oasis": 0.3, "delta": 0.3, "beach": 0.15}'),
    (2, 'castle', 'castle', 'Fortress',        0.3,    30,   50,   400,  1200, 'The Fortress of {A}{B}', ARRAY['hold', 'gard', 'mont', 'crest'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1, "oasis": 1, "delta": 1, "beach": 0.5}'),
    (2, 'ruins',  'ruins',  'Ruined city',     0.25,   20,   45,  1000,  3000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (3, 'peak',   'peak',   'Mountain',        0.3,   800, 2500,  4000, 15000, '{A}{B}',            ARRAY['fell', 'pike', 'crag', 'howe'],    '{"mountains": 1}'),
    (3, 'castle', 'castle', 'Castle',          0.3,    25,   35,    80,   250, '{A}{B} Castle',     ARRAY['hold', 'gard', 'mont', 'crest', 'wall', 'keep'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1, "oasis": 1, "delta": 1, "beach": 0.5}'),
    (3, 'ruins',  'ruins',  'Ruined castle',   0.2,    15,   30,    60,   200, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'wall', 'keep'],  '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (3, 'tower',  'tower',  'Great tower',     0.2,    35,   60,    10,    18, '{A} Tower',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (4, 'peak',   'peak',   'Hill',            0.2,   150,  800,   800,  4000, '{A} {B}',           ARRAY['Tor', 'Fell', 'Howe', 'Law', 'Knott'], '{"mountains": 1, "hills": 1}'),
    (4, 'castle', 'castle', 'Tower house',     0.15,   15,   25,    20,    60, '{A}{B} Keep',       ARRAY['hold', 'gard', 'mont', 'crest', 'wall'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1, "oasis": 1, "delta": 1, "beach": 0.5}'),
    (4, 'ruins',  'ruins',  'Ruined chapel',   0.2,     8,   20,    10,    30, '{A} Chapel',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (4, 'tower',  'tower',  'Watchtower',      0.2,    15,   30,     6,    10, '{A} Watch',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (4, 'stones', 'stones', 'Stone circle',    0.25,    2,    5,    30,   110, 'The {A} Stones',    ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (5, 'peak',   'peak',   'Crag',            0.2,    30,  150,   100,   600, '{A} {B}',           ARRAY['Crag', 'Scar', 'Knott', 'Nab'],    '{"mountains": 1, "hills": 1}'),
    (5, 'castle', 'castle', 'Motte',           0.1,     8,   15,    30,    60, '{A} Mount',         ARRAY[''],                                '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1, "oasis": 1, "delta": 1, "beach": 0.5}'),
    (5, 'ruins',  'ruins',  'Ruined croft',    0.25,    3,    6,     6,    15, '{A} Croft',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (5, 'tower',  'tower',  'Beacon',          0.15,    6,   12,     3,     6, '{A} Beacon',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (5, 'stone',  'stone',  'Great standing stone', 0.3, 4,   8,     1,   2.5, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (6, 'rock',   'rock',   'Boulder',         0.35,    2,    8,     3,    12, '{A} Rock',          ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.7, "desert": 0.6, "land": 0.5, "plains": 0.4, "forest": 0.4, "pine": 0.4, "savanna": 0.5, "dunes": 0.3, "salt": 0.12, "oasis": 0.5, "delta": 0.5, "beach": 0.25}'),
    (6, 'ruins',  'ruins',  'Broken wall',     0.2,   1.5,    4,     2,     8, '{A} Wall',          ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (6, 'stone',  'stone',  'Standing stone',  0.3,   1.2,  3.5,   0.5,   1.2, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (6, 'cairn',  'cairn',  'Cairn',           0.15,    1,    3,     2,     6, '{A} Cairn',         ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.8, "desert": 0.4, "land": 0.3, "plains": 0.3, "pine": 0.2, "savanna": 0.3, "dunes": 0.2, "salt": 0.08, "oasis": 0.3, "delta": 0.3, "beach": 0.15}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_location_kinds()
 RETURNS TABLE(rank integer, kind text, icon text, words text, weight double precision, h_low double precision, h_high double precision, w_low double precision, w_high double precision, pattern text, ends text[], grounds jsonb)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The places to go into of the world map (step 12c; Peter 2026-10-06: smaller places to go into, caves, shrines, mines,
-- camps, huts, rolled like towns and never stored), the one home of what each can be, read as rpg_map_landmark_kinds is
-- (the same columns, the same meaning): rank = the coarsest grid that shows it (4 the Region grid to 6 the District
-- grid); weight = its share of the places of its rank (they add up to 1); h_low, h_high = how tall it stands in metres
-- (a cave or a mine: the rock over its mouth; a camp: its tents, or the palisade of a war camp); w_low, w_high = how far
-- across; pattern and ends = its name. Worked out when asked, never stored.
-- The sizes are of real ones: a great cave mouth in a cliff 15 to 40 m high (the Peak Cavern entrance, Derbyshire, is
-- 30 m wide and 18 m high); a cave a hillside knoll 6 to 20 m high; a mine's workings 60 to 200 m across of spoil heaps
-- round its adit, a lone mine 15 to 40 m; a Roman marching camp 2 to 4 m palisade round 80 to 200 m of tents for a
-- cohort or two; a shrine or chapel of ease 5 to 10 m across; a wayside cross 2 to 3.5 m; a hut or a shieling 4 to
-- 9 m across (a Highland bothy 5 by 4 m); a camp of a band 20 to 50 m across, a campsite 8 to 15 m.
-- Caves and mines on mountains and hills, a cave of the City grid in a wood too; shrines and huts on any dry ground;
-- camps in woods and on open land. Nothing in the sea, water, snow and ice, a road, or inside a place with ground of its own.
-- More terrain step 1 (2026-10-10): savanna and scrub weighs as open land (the ground it was), bog as swamp, sand dunes
-- half of desert, salt flats a fifth of desert.
-- Step 2b: an oasis and a river delta weigh as open land.
-- Step 3a: a beach weighs half as open land.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (4, 'cave',   'cave',   'Great cave',      0.4,    15,   40,    40,   120, '{A} {B}', ARRAY['Cavern', 'Caves', 'Deeps'],     '{"mountains": 1, "hills": 0.8}'),
    (4, 'mine',   'mine',   'Mine workings',   0.3,     6,   15,    60,   200, '{A} {B}', ARRAY['Mine', 'Delving', 'Workings'],  '{"mountains": 1, "hills": 0.8, "tundra": 0.2}'),
    (4, 'camp',   'camp',   'War camp',        0.3,     3,    5,    80,   200, '{A} {B}', ARRAY['Camp', 'Stockade'],             '{"plains": 1, "land": 0.8, "hills": 0.6, "forest": 0.6, "pine": 0.5, "desert": 0.4, "tundra": 0.3, "jungle": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (5, 'cave',   'cave',   'Cave',            0.3,     6,   20,    15,    40, '{A} {B}', ARRAY['Cave', 'Hole', 'Grotto'],       '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3, "jungle": 0.3}'),
    (5, 'mine',   'mine',   'Mine',            0.15,    3,    8,    15,    40, '{A} {B}', ARRAY['Mine', 'Adit', 'Delving'],      '{"mountains": 1, "hills": 0.8}'),
    (5, 'shrine', 'shrine', 'Shrine',          0.2,     4,    8,     5,    10, '{A} {B}', ARRAY['Shrine', 'Sanctum'],            '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "bog": 0.3, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (5, 'camp',   'camp',   'Camp',            0.15,    2,    3,    20,    50, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3, "savanna": 0.6, "dunes": 0.25, "salt": 0.1, "bog": 0.3, "oasis": 0.6, "delta": 0.6, "beach": 0.3}'),
    (5, 'hut',    'hut',    'Hut',             0.2,     3,    5,     5,     9, '{A} {B}', ARRAY['Hut', 'Lodge', 'Bothy'],        '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3, "savanna": 0.8, "dunes": 0.15, "salt": 0.06, "bog": 0.5, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (6, 'cave',   'cave',   'Hollow',          0.3,     3,    8,     6,    15, '{A} {B}', ARRAY['Hollow', 'Hole'],               '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3}'),
    (6, 'shrine', 'shrine', 'Wayside shrine',  0.25,    2,  3.5,     1,   2.5, '{A} {B}', ARRAY['Cross', 'Shrine'],              '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "bog": 0.3, "oasis": 0.8, "delta": 0.8, "beach": 0.4}'),
    (6, 'camp',   'camp',   'Campsite',        0.2,   1.5,  2.5,     8,    15, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3, "savanna": 0.6, "dunes": 0.25, "salt": 0.1, "bog": 0.3, "oasis": 0.6, "delta": 0.6, "beach": 0.3}'),
    (6, 'hut',    'hut',    'Hut',             0.25,    3,  4.5,     4,     7, '{A} {B}', ARRAY['Hut', 'Bothy'],                 '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3, "savanna": 0.8, "dunes": 0.15, "salt": 0.06, "bog": 0.5, "oasis": 0.8, "delta": 0.8, "beach": 0.4}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_icons()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp; savanna and scrub, sand dunes,
-- salt flats, bog; oasis, river delta; beach) are symbols too. So are
-- a town and a city (step 8: the villages, towns and cities that grow on the land, rpg_map_towns), a great city
-- (step 12a), and the landmarks (step 12b, rpg_map_landmark_kinds): a peak, a castle, a tower, a stone circle, a
-- standing stone, a boulder and a cairn (ruins was already one), and the places to go into (step 12c,
-- rpg_map_location_kinds): a cave, a mine, a shrine, a camp and a hut.
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'savanna', 'dunes', 'salt', 'bog', 'oasis', 'delta', 'beach', 'town', 'city', 'great_city',
             'peak', 'castle', 'tower', 'stones', 'stone', 'rock', 'cairn', 'cave', 'mine', 'shrine', 'camp', 'hut'];
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_lie(p_kind text, p_shore boolean, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What lies on one square of the battle grid (step 14f-battle, Peter 2026-10-08 18:52, 1A), the one home of it, by its
-- ground and one fixed d100 of the square (rpg_map_roll, layer 1801), so nothing is stored:
--   boulder  hills (map_boulder_hills_share, 2 in 100 squares) and mountains (map_boulder_mountains_share, 6): a rock
--            higher than a person. Nobody walks into it, and a fighter just behind one from the attacker is in full
--            cover (rpg_cover).
--   log      forest, pine forest and jungle (map_log_share, 3 in 100: fallen trunks cover a few in 100 of the floor of
--            a forest, Harmon et al. 1986, Ecology of coarse woody debris in temperate ecosystems). It adds
--            map_log_penalty (+100%) to the time the square takes, and a fighter just behind one from the attacker is
--            in half cover (rpg_cover).
--   reeds    dry ground at the edge of a river or a lake (p_shore), unless desert, sand dunes, salt flats or snow and ice (map_shore_reed_share,
--            50 in 100). Drawn only.
-- rpg_map_costs reads it for every battle grid square it may lie on (not a road, a town, a place, a building or a cliff).
SELECT CASE
         WHEN p_kind = 'hills' AND r.d <= s.bh THEN 'boulder'
         WHEN p_kind = 'mountains' AND r.d <= s.bm THEN 'boulder'
         WHEN p_kind IN ('forest', 'pine', 'jungle') AND r.d <= s.lg THEN 'log'
         WHEN p_shore AND p_kind NOT IN ('desert', 'dunes', 'salt', 'beach', 'ice', 'sea', 'water', 'deep') AND r.d > 100 - s.rd THEN 'reeds'
       END
  FROM (SELECT public.rpg_map_roll((SELECT st.value FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st.key = 'map_seed')::integer,
                                   1801, p_x, p_y) AS d) r
 CROSS JOIN (SELECT max(st.value) FILTER (WHERE st.key = 'map_boulder_hills_share') AS bh,
                    max(st.value) FILTER (WHERE st.key = 'map_boulder_mountains_share') AS bm,
                    max(st.value) FILTER (WHERE st.key = 'map_log_share') AS lg,
                    max(st.value) FILTER (WHERE st.key = 'map_shore_reed_share') AS rd
               FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365') s;
$function$;
UPDATE public.rpg_rules SET body = $rb$The world map is made of the same squares a fight is played on, each 3 feet 8 inches across, and the world is the size of the Earth: 24,901 miles around. The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board. Each cell of a grid shows the ground most of the land inside it holds, so zooming in keeps every coast, mountain chain, wood and climate where it was, only finer.

On a journey everyone takes turns on one clock, the same clock a fight uses. A tick is a sixth of a second, so an hour is 21,600 ticks.

On its turn a piece walks toward any square the game master picks, the whole way in one go: straight, or along the roads (see below). Every square it steps into takes 5 ticks at Speed 10 plus the share of time that square adds, faster or slower by Speed like everything else. The ranges are the same as on a fight board: open land +0% to +10%, forest +20% to +150% with thickets at +400%, mountains +200% to +500%, and so on. A walk longer than about 7 miles counts each 1.2-mile stretch as the average square of its ground. The climate shapes the land: snow and ice, then tundra, toward the poles; pine forest in the cold; desert where it is driest, with seas of sand dunes in its driest parts and salt flats in its lowest ground; grassy plains where it is dry; savanna and scrub where it is warm and a little drier than jungle; jungle where it is hot and wet; swamp in wet lowlands, and bog where those lowlands are cold. Savanna and scrub is +5% to +50%, sand dunes +80% to +150%, salt flats +0% to +15%, bog +50% to +150%. In a desert, a shallow hollow where the ground water comes up is an oasis, +5% to +40%: a spring, grass and palms. Where a great river or a river reaches the sea its low ground is a delta, +40% to +140%: silt, reeds and channels; a great river's delta is about 70 km across. Where low land meets the sea, its last 30 squares (about 33 m) are beach, +20% to +60% of sand. Where hills meet the sea they end in a sea cliff 20 m high at 70 degrees, and mountains in one 60 m high at 80 degrees, climbed square by square like any cliff (see Climbing). Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, +25% to +75%. One mountain square in twenty is a cliff, climbed with a Climbing roll (see Climbing). Where a stream, river or great river runs through hills or mountains it has cut a gorge. Its walls are cliffs from the water's edge to the rim, climbed square by square like any cliff (see Climbing): 55 degrees in hills, 70 in mountains. A stream's gorge is 8 m deep in hills and 24 m in mountains, a river's 25 m and 75 m, a great river's 40 m and 120 m; brooks cut none. A road crosses on its bridge.
*At Speed 10 a mile of savanna, +27.5% on average, is 1,439 x 5 x 1.275 = 9,174 ticks, about 25 minutes; a mile of sand dunes, +115%, is 15,469 ticks, about 43 minutes; a mile of salt flat, +7.5%, is 7,735 ticks, about 21 minutes; a mile of bog, +100%, is 14,390 ticks, 40 minutes. A mile of oasis, +22.5% on average, is 1,439 x 5 x 1.225 = 8,814 ticks, about 24 minutes; a mile of delta, +90%, is 13,671 ticks, about 38 minutes. Along a beach, +40% on average, a mile is 1,439 x 5 x 1.4 = 10,073 ticks, about 28 minutes. A hill sea cliff's face is 20 / tan 70 = 7.3 m, about 7 squares wide.*
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

