-- roleplaying map step 11: bridges and fords (Peter 2026-10-04 13:44: bridges across rivers in some spots where roads
-- cross, planned fords in other spots, including some spots where roads cross). Settings map_bridge_1/2/3,
-- map_ford_span, map_ford_share; new rpg_map_road_key, rpg_map_crossing_kind, rpg_map_fords, rpg_map_ford_cells;
-- rpg_map_roads (battle grid reads kept a transaction), rpg_map_road_cells (same ask), rpg_map_flow (ford depth),
-- rpg_map_cells (a ford stays water under a road), rpg_map_view_block (crossings, cross); rule cards world_map, moving.

-- step 11: bridges and fords (Peter 2026-10-04 13:44: bridges across rivers in some spots where roads cross, planned
-- fords in other spots, including some spots where roads cross)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label
  FROM (VALUES ('map_bridge_1', 100::numeric, 'Highways: in 100, how many of the rivers and streams a stretch meets it bridges; the rest it fords (a great river is always bridged)'),
               ('map_bridge_2', 65, 'Roads: in 100, how many of the rivers and streams a stretch meets it bridges; the rest it fords'),
               ('map_bridge_3', 35, 'Lanes: in 100, how many of the rivers and streams a stretch meets it bridges; the rest it fords'),
               ('map_ford_span', 16, 'Fords: how far along the river a ford is knee-deep, in squares (9 m), bank to bank'),
               ('map_ford_share', 8, 'Planned fords: in 100, how many of the City cells a river or stream runs through hold a ford off the roads')) AS v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = v.key);

CREATE OR REPLACE FUNCTION public.rpg_map_road_key(p_a text, p_b text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The number a stretch of road rolls by (step 11): the first 8 hex digits of the md5 of its two ends, the one that
-- sorts first first, so the stretch from A to B and the one from B to A are the same stretch. The same number steers
-- the wandering of its line (rpg_map_road_lines).
SELECT ('x' || substr(md5(least(p_a, p_b) || '>' || greatest(p_a, p_b)), 1, 8))::bit(32)::integer;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_crossing_kind(p_class integer, p_k integer, p_a text, p_b text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How a stretch of road (p_class: 1 highway, 2 road, 3 lane; p_a, p_b its ends) crosses a river of size p_k (2 a great
-- river, 3 a river, 4 a stream, 5 a brook), the one home of that call (step 11): 1 a bridge, 2 a ford. A great river
-- is always bridged (400 m wide and 8 m deep, no ford), a brook never needs more than a plank (road ground over it).
-- For a river or a stream the stretch rolls once for each size (rpg_map_roll, part 15, layer 1500 + size, at its key,
-- rpg_map_road_key): a roll of at most map_bridge_<class> (highways 100, roads 65, lanes 35, in 100) builds a bridge,
-- a higher one a ford. So every highway bridges every river, a lane fords about two of three. One roll a stretch and
-- size: a lane that fords the river it meets fords it at every crossing, at every zoom.
SELECT CASE WHEN p_k NOT IN (3, 4) THEN 1
            WHEN public.rpg_map_roll((SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer,
                                     1500 + p_k, public.rpg_map_road_key(p_a, p_b), 0)
                 <= (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_bridge_' || p_class) THEN 1
            ELSE 2 END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_fords(p_x0 double precision, p_y0 double precision, p_x1 double precision, p_y1 double precision, p_classes integer[])
 RETURNS TABLE(k integer, x double precision, y double precision, ux double precision, uy double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The planned fords of the rivers and streams in a box of the world (squares: p_x0, p_y0 to p_x1, p_y1), worked out
-- when asked and never stored: the one home of where a river is forded off the roads (step 11, Peter 2026-10-04:
-- planned fords in other spots). Each City cell a river (3) or a stream (4) runs through rolls once for a ford
-- (rpg_map_roll, part 14, layer 1400 + size, at the cell): a roll of at most map_ford_share (8 in 100) puts a ford
-- where the line of the river passes nearest the middle of the cell, read on the District grid (rpg_map_rivers at
-- level 6, whose line is the one the battle grid shows within a square or two). A great river has no ford (8 m deep)
-- and a brook needs none (ankle-deep); p_classes = the sizes asked about.
-- Per ford: k = the size of the river, x, y = the anchor, the point of the line it is centred on, in squares, ux, uy =
-- the way the river runs there (unit), the main axis of the line points within 2.5 District cells of the anchor. The
-- ford is the water within map_ford_span / 2 squares of the anchor along the river, bank to bank (rpg_map_ford_cells),
-- knee-deep: map_wade_ford_depth (0.5 m), rpg_map_flow. The City grid is read first over the box, to find the cells
-- the line of each size comes within 1.2 cells of and where in each it passes; the District grid is then read only in
-- the cells that roll a ford, and only round that point (3 District cells each way for a river, whose District line
-- lies within about 15 squares of its City line; the whole cell for a stream, whose line moves up to 60), and only
-- inside the cell, so a ford is its own cell's and never a neighbour's. Each City cell and size is worked out once a
-- transaction (rpg.fords5: its anchor, or none), since a walk and the battle grid ask for the same cells many times.
DECLARE
  v_c5    double precision;
  v_cache jsonb;
  v_new   jsonb;
BEGIN
  SELECT l.cell INTO v_c5 FROM public.rpg_map_ladder() l WHERE l.level = 5;
  v_cache := coalesce(nullif(current_setting('rpg.fords5', true), ''), '{}')::jsonb;
  -- the cells and sizes of the box not yet known: worked out together, over the box that holds them
  WITH cls AS (SELECT q.k FROM unnest(coalesce(p_classes, '{}'::integer[])) AS q(k) WHERE q.k IN (3, 4)),
       lad AS (SELECT (SELECT l.across FROM public.rpg_map_ladder() l WHERE l.level = 5) AS across,
                      (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 5) AS down),
       cc AS (SELECT gx, gy, mod(mod(gx, lad.across) + lad.across, lad.across) AS wx, cls.k
                FROM lad CROSS JOIN cls
               CROSS JOIN LATERAL generate_series(floor(p_x0 / v_c5)::integer, floor(p_x1 / v_c5)::integer) AS gx
               CROSS JOIN LATERAL generate_series(greatest(0, floor(p_y0 / v_c5)::integer), least(lad.down - 1, floor(p_y1 / v_c5)::integer)) AS gy
               WHERE NOT (v_cache ? (gx || ':' || gy || ':' || cls.k))),
       n AS (SELECT count(*) AS cells, min(cc.gx) AS gx0, min(cc.gy) AS gy0, max(cc.gx) - min(cc.gx) + 1 AS cols, max(cc.gy) - min(cc.gy) + 1 AS rows FROM cc),
       st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
       cfg AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_seed')::integer AS seed,
                      (SELECT st.value FROM st WHERE st.key = 'map_ford_share') AS share,
                      (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 6)::double precision AS c6),
       -- the cells that roll a ford, for each size asked about
       rl AS (SELECT cc.gx, cc.gy, cc.k FROM cc CROSS JOIN cfg WHERE public.rpg_map_roll(cfg.seed, 1400 + cc.k, cc.wx, cc.gy) <= cfg.share),
       -- the City grid over those cells: the cells the line of each size comes near, and where in each it passes
       pre AS MATERIALIZED (
         SELECT r.x, r.y, r.k, r.px, r.py
           FROM n CROSS JOIN LATERAL public.rpg_map_rivers(5, n.gx0::integer, n.gy0::integer, n.cols::integer, n.rows::integer) r
          WHERE n.cells > 0 AND EXISTS (SELECT 1 FROM rl) AND r.k IN (SELECT cls.k FROM cls) AND r.dist <= 1.2 * v_c5),
       cand AS (SELECT rl.gx, rl.gy, rl.k, pre.px, pre.py FROM rl JOIN pre ON pre.x = rl.gx AND pre.y = rl.gy AND pre.k = rl.k),
       -- the line of each candidate on the District grid, round the point its City line passes and inside its cell:
       -- the cells it runs through, with the point of the line in each, in squares
       dl AS MATERIALIZED (
         SELECT cand.gx, cand.gy, cand.k, (r.x + 0.5 + r.px) * cfg.c6 AS lx, (r.y + 0.5 + r.py) * cfg.c6 AS ly
           FROM cand CROSS JOIN cfg
          CROSS JOIN LATERAL (SELECT (v_c5 / cfg.c6)::integer AS sub, CASE WHEN cand.k = 3 THEN 3 ELSE 6 END AS r) q
          CROSS JOIN LATERAL (SELECT greatest(cand.gx * q.sub, floor((cand.gx + 0.5 + cand.px) * q.sub)::integer - q.r) AS x0,
                                     least(cand.gx * q.sub + q.sub - 1, floor((cand.gx + 0.5 + cand.px) * q.sub)::integer + q.r) AS x1,
                                     greatest(cand.gy * q.sub, floor((cand.gy + 0.5 + cand.py) * q.sub)::integer - q.r) AS y0,
                                     least(cand.gy * q.sub + q.sub - 1, floor((cand.gy + 0.5 + cand.py) * q.sub)::integer + q.r) AS y1) b
          CROSS JOIN LATERAL public.rpg_map_rivers(6, b.x0, b.y0, b.x1 - b.x0 + 1, b.y1 - b.y0 + 1) r
          WHERE b.x1 >= b.x0 AND b.y1 >= b.y0 AND r.k = cand.k AND r.inside),
       -- the anchor: the point of the line nearest the middle of the City cell
       an AS (SELECT DISTINCT ON (dl.gx, dl.gy, dl.k) dl.gx, dl.gy, dl.k, dl.lx AS ax, dl.ly AS ay
                FROM dl
               ORDER BY dl.gx, dl.gy, dl.k, power(dl.lx - (dl.gx + 0.5) * v_c5, 2) + power(dl.ly - (dl.gy + 0.5) * v_c5, 2)),
       -- the way the river runs at the anchor: the main axis of the line points round it
       ax AS (SELECT an.gx, an.gy, an.k, an.ax, an.ay, count(*) AS pts, var_pop(dl.lx) AS vx, var_pop(dl.ly) AS vy, covar_pop(dl.lx, dl.ly) AS cxy
                FROM an CROSS JOIN cfg
                JOIN dl ON dl.gx = an.gx AND dl.gy = an.gy AND dl.k = an.k AND power(dl.lx - an.ax, 2) + power(dl.ly - an.ay, 2) <= power(2.5 * cfg.c6, 2)
               GROUP BY an.gx, an.gy, an.k, an.ax, an.ay),
       fd AS (SELECT ax.gx, ax.gy, ax.k, ax.ax, ax.ay, cos(t.a) AS ux, sin(t.a) AS uy
                FROM ax CROSS JOIN LATERAL (SELECT 0.5 * atan2(2 * ax.cxy, ax.vx - ax.vy) AS a) t
               WHERE ax.pts >= 2)
  SELECT coalesce(jsonb_object_agg(cc.gx || ':' || cc.gy || ':' || cc.k,
                                   CASE WHEN fd.k IS NULL THEN 'null'::jsonb ELSE jsonb_build_array(fd.ax, fd.ay, fd.ux, fd.uy) END), '{}'::jsonb)
    INTO v_new
    FROM cc LEFT JOIN fd ON fd.gx = cc.gx AND fd.gy = cc.gy AND fd.k = cc.k;
  IF v_new <> '{}'::jsonb THEN
    v_cache := v_cache || v_new;
    PERFORM set_config('rpg.fords5', v_cache::text, true);
  END IF;
  RETURN QUERY
    SELECT (split_part(e.key, ':', 3))::integer, (e.value ->> 0)::double precision, (e.value ->> 1)::double precision, (e.value ->> 2)::double precision, (e.value ->> 3)::double precision
      FROM jsonb_each(v_cache) AS e(key, value)
     WHERE jsonb_typeof(e.value) = 'array'
       AND (split_part(e.key, ':', 3))::integer = ANY (coalesce(p_classes, '{}'::integer[]))
       AND (e.value ->> 0)::double precision BETWEEN p_x0 AND p_x1 AND (e.value ->> 1)::double precision BETWEEN p_y0 AND p_y1
       AND (split_part(e.key, ':', 1))::integer BETWEEN floor(p_x0 / v_c5)::integer AND floor(p_x1 / v_c5)::integer
       AND (split_part(e.key, ':', 2))::integer BETWEEN floor(p_y0 / v_c5)::integer AND floor(p_y1 / v_c5)::integer;
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_ford_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, kind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid where a river or a stream is forded (step 11): knee-deep water the walk
-- wades, where the river would be deep. Two kinds. ford: a road crosses the river by a ford (rpg_map_crossing_kind
-- says so for that stretch and that size of river): the water within map_ford_span / 2 squares (8, 9 m) of the line
-- of the road (rpg_map_road_lines), bank to bank, so the ford is as wide as a road needs and a little more. planned: a
-- ford off the roads (rpg_map_fords): the water within map_ford_span / 2 of the anchor along the river, bank to bank.
-- Only rivers (3) and streams (4): a great river is bridged, a brook is ankle-deep. k = the size of the river forded.
-- rpg_map_flow caps the depth of these squares at map_wade_ford_depth (0.5 m); rpg_map_cells keeps them water where a
-- road runs over them (the road goes through the ford), where a bridge is road ground; rpg_map_view_block tells them
-- apart. Only the battle grid has squares: nothing on a coarser grid. A small block (up to two District cells each
-- way) is answered from whole District cells, each worked out once a transaction (rpg.fords), since the water, the
-- ground, the picture and every run of a walk ask for the same ground; a bigger block is worked out as asked.
DECLARE
  v_c6  integer;
  v_key text;
  v_all jsonb;
  v_c   jsonb;
BEGIN
  IF p_level <> 7 THEN RETURN; END IF;
  SELECT l.cell INTO v_c6 FROM public.rpg_map_ladder() l WHERE l.level = 6;
  IF p_cols > 2 * v_c6 OR p_rows > 2 * v_c6 THEN
    v_key := NULL;
  ELSIF p_cols <> v_c6 OR p_rows <> v_c6 OR mod(mod(p_x0, v_c6) + v_c6, v_c6) <> 0 OR mod(mod(p_y0, v_c6) + v_c6, v_c6) <> 0 THEN
    RETURN QUERY
      SELECT f.x, f.y, f.k, f.kind
        FROM generate_series(floor(p_x0::numeric / v_c6)::integer, floor((p_x0 + p_cols - 1)::numeric / v_c6)::integer) AS gx
       CROSS JOIN generate_series(floor(p_y0::numeric / v_c6)::integer, floor((p_y0 + p_rows - 1)::numeric / v_c6)::integer) AS gy
       CROSS JOIN LATERAL public.rpg_map_ford_cells(7, gx * v_c6, gy * v_c6, v_c6, v_c6) f
       WHERE f.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND f.y BETWEEN p_y0 AND p_y0 + p_rows - 1;
    RETURN;
  ELSE
    v_key := p_x0 || ':' || p_y0;
  END IF;
  v_all := coalesce(nullif(current_setting('rpg.fords', true), ''), '{}')::jsonb;
  v_c := CASE WHEN v_key IS NOT NULL THEN v_all -> v_key END;
  IF v_c IS NULL THEN
    WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
         w AS (SELECT q.k, (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width FROM generate_series(3, 4) AS q(k)),
         cfg AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_ford_span')::double precision / 2 AS half),
         -- the squares of the block with a river or a stream over their middle
         rv AS MATERIALIZED (
           SELECT r.x, r.y, r.k, w.width
             FROM public.rpg_map_rivers(7, p_x0, p_y0, p_cols, p_rows) r JOIN w ON w.k = r.k
            WHERE r.dist < w.width / 2),
         -- the roads whose lines may come within half a ford of the block (asked for with the same margin as the road
         -- squares of the block, rpg_map_road_cells, so the two share one answer), and which sizes of river each fords
         lg AS MATERIALIZED (
           SELECT row_number() OVER () AS n, r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b,
                  public.rpg_map_crossing_kind(r.class, 3, r.a, r.b) = 2 AS ford3, public.rpg_map_crossing_kind(r.class, 4, r.a, r.b) = 2 AS ford4
             FROM cfg CROSS JOIN LATERAL public.rpg_map_roads(7, p_x0, p_y0, p_cols, p_rows, 7, NULL, greatest(12, cfg.half + 1)) r
            WHERE EXISTS (SELECT 1 FROM rv)),
         la AS (SELECT array_agg(lg.class ORDER BY lg.n) AS class, array_agg(lg.ax ORDER BY lg.n) AS ax, array_agg(lg.ay ORDER BY lg.n) AS ay,
                       array_agg(lg.bx ORDER BY lg.n) AS bx, array_agg(lg.by ORDER BY lg.n) AS by, array_agg(lg.a ORDER BY lg.n) AS a, array_agg(lg.b ORDER BY lg.n) AS b,
                       array_agg(lg.ford3 ORDER BY lg.n) AS ford3, array_agg(lg.ford4 ORDER BY lg.n) AS ford4
                  FROM lg WHERE lg.ford3 OR lg.ford4 HAVING count(*) > 0),
         -- the points of those lines near the block, and the pieces between them
         lp AS MATERIALIZED (
           SELECT p.i, p.n, p.x, p.y
             FROM la CROSS JOIN cfg
            CROSS JOIN LATERAL public.rpg_map_road_lines(la.class, la.ax, la.ay, la.bx, la.by, la.a, la.b, 1.0, NULL,
                                                         p_x0 - cfg.half - 1, p_y0 - cfg.half - 1, p_x0 + p_cols + cfg.half + 1, p_y0 + p_rows + cfg.half + 1) p),
         sg AS (SELECT a.i, a.x AS ax, a.y AS ay, b.x AS bx, b.y AS by FROM lp a JOIN lp b ON b.i = a.i AND b.n = a.n + 1),
         -- a road ford: the river squares within half a ford of a piece of a road that fords that size of river
         rf AS (SELECT DISTINCT rv.x, rv.y, rv.k
                  FROM rv CROSS JOIN la CROSS JOIN cfg JOIN sg ON (rv.k = 3 AND la.ford3[sg.i]) OR (rv.k = 4 AND la.ford4[sg.i])
                 CROSS JOIN LATERAL (SELECT rv.x + 0.5 - sg.ax AS px, rv.y + 0.5 - sg.ay AS py, sg.bx - sg.ax AS dx, sg.by - sg.ay AS dy) v
                 CROSS JOIN LATERAL (SELECT CASE WHEN v.dx * v.dx + v.dy * v.dy = 0 THEN 0
                                                 ELSE least(greatest((v.px * v.dx + v.py * v.dy) / (v.dx * v.dx + v.dy * v.dy), 0), 1) END AS t) t
                 WHERE power(v.px - t.t * v.dx, 2) + power(v.py - t.t * v.dy, 2) <= cfg.half * cfg.half),
         -- a planned ford whose water may reach the block: the river squares within half a ford of its anchor along
         -- the river, and within the width of the river of it across
         an AS MATERIALIZED (
           SELECT f.k, f.x, f.y, f.ux, f.uy
             FROM cfg CROSS JOIN (SELECT max(w.width) / 2 + 2 AS reach FROM w) m
            CROSS JOIN LATERAL public.rpg_map_fords(p_x0 - cfg.half - m.reach, p_y0 - cfg.half - m.reach, p_x0 + p_cols + cfg.half + m.reach, p_y0 + p_rows + cfg.half + m.reach,
                                                    (SELECT array_agg(DISTINCT rv.k) FROM rv)) f
            WHERE EXISTS (SELECT 1 FROM rv)),
         pf AS (SELECT DISTINCT rv.x, rv.y, rv.k
                  FROM rv JOIN an ON an.k = rv.k CROSS JOIN cfg
                 WHERE abs((rv.x + 0.5 - an.x) * an.ux + (rv.y + 0.5 - an.y) * an.uy) <= cfg.half
                   AND abs((rv.y + 0.5 - an.y) * an.ux - (rv.x + 0.5 - an.x) * an.uy) <= rv.width / 2 + 2)
    SELECT coalesce(jsonb_agg(jsonb_build_array(q.x, q.y, q.k, q.kind) ORDER BY q.y, q.x, q.k), '[]'::jsonb)
      INTO v_c
      FROM (SELECT DISTINCT ON (u.x, u.y, u.k) u.x, u.y, u.k, u.kind
              FROM (SELECT rf.x, rf.y, rf.k, 'ford' AS kind FROM rf
                    UNION ALL
                    SELECT pf.x, pf.y, pf.k, 'planned' FROM pf) u
             ORDER BY u.x, u.y, u.k, u.kind) q;
    IF v_key IS NOT NULL THEN PERFORM set_config('rpg.fords', jsonb_set(v_all, ARRAY[v_key], v_c)::text, true); END IF;
  END IF;
  RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::integer, (e.v ->> 2)::integer, e.v ->> 3 FROM jsonb_array_elements(v_c) AS e(v);
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_roads(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_what integer DEFAULT 7, p_towns jsonb DEFAULT NULL::jsonb, p_pad double precision DEFAULT 0)
 RETURNS TABLE(class integer, ax double precision, ay double precision, bx double precision, by double precision, a text, b text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The roads near a block of any grid, worked out when asked and never stored: the one home of where roads run (step
-- 8b; Peter 2026-10-03 17:28: roads between places). Every road runs straight from one place to the next, the way the
-- medieval network ran from settlement to settlement (the Gough Map, c. 1360: about 600 places and 4,542 km of road in
-- 455 stretches, most under 10 km), at three sizes:
--   1 highway   from a city to each neighbouring city: the cities of the city squares beside its own, and of a square
--               corner to corner with it when the two other cities of that square of four stand outside the circle
--               across the two (the Gabriel test, Gabriel and Sokal 1969: at most one diagonal a square of four), through
--               the town site of every town square on the way, so it runs from town to town (Christaller 1933, the
--               traffic principle);
--               map_road_1_width (5.8 squares, 6.5 m: the average of some 500 principal Roman roads);
--   2 road      from a town or city to each neighbouring town or city, the same way among the town sites, straight from
--               one to the next (English market towns stood about a third of a day apart, Bracton: a new market within
--               6 2/3 miles of another harmed it); map_road_2_width (4.4, 4.9 m: two carts pass, Leges Henrici Primi);
--   3 lane      from each village to the next village on its way to its market (the town site of its town square,
--               rpg_map_hub), a step of the village lattice at a time toward it, to the first site on the way that has
--               people; a village, town or city place card (Haven) joins the same way from its own village square;
--               map_road_3_width (2.1, 2.4 m: the 8 Roman feet of the Twelve Tables, one cart).
-- A highway or road needs a city or a town at both ends (rpg_map_town_at), a lane people at both ends (rpg_map_towns).
-- No road crosses the oval of a place whose ground is rougher than a road (place_penalty above map_road_penalty_high:
-- Old Forest, the Fog); open places (Haven, Abandoned Borderlands) are crossed and keep their own ground.
-- What a block gets: p_what adds 1 for highways, 2 for roads, 4 for lanes; nothing on a grid coarser than the Country
-- grid, and the roads and lanes only from the Region grid down. Every stretch whose line may come within p_pad squares,
-- plus half the widest road, of the block, once: class, its two ends a and b in world squares counted the way the block
-- counts (a block past the east or west end of the world keeps its own count), and the places at its ends
-- (site-<column>-<row> of a site, or the id of a place card). A stretch wanders about the straight line between its
-- ends (step 10b, rpg_map_road_lines): the stretches looked at are those whose straight line comes within the
-- farthest a road wanders (rpg_map_road_swing) of that margin, and of those only the ones whose line may reach it
-- (rpg_map_road_reaches) have their ends read. p_towns = what grows at the sites inside this very block
-- (id: city, town or village, as rpg_map_towns reads them; a site inside it that is not named has no one) when the
-- caller has it (Country grid: its cities; Region grid: all three), so nothing inside the block is read twice; the
-- ends outside it are read only when the other end of their stretch has the town or city it needs.
#variable_conflict use_column
DECLARE
  c record; v_cell bigint; v_c4 bigint; v_high integer; v_pad double precision; v_k bigint; v_cs double precision; v_ts double precision;
  v_x0 double precision; v_y0 double precision; v_x1 double precision; v_y1 double precision; v_far double precision;
  t_x0 double precision; t_y0 double precision; t_x1 double precision; t_y1 double precision; v_keep integer[];
  v_bx0 bigint; v_by0 bigint; v_bx1 bigint; v_by1 bigint; v_ek jsonb;
  p_x double precision[]; p_y double precision[]; p_vx bigint[]; p_vy bigint[]; p_id text[]; p_k0 integer[]; p_tx double precision[]; p_ty double precision[]; p_a text[]; p_b text[];
  o_cls integer[] := '{}'; o_ax double precision[] := '{}'; o_ay double precision[] := '{}'; o_bx double precision[] := '{}';
  o_by double precision[] := '{}'; o_a text[] := '{}'; o_b text[] := '{}';
  h_pvx bigint[]; h_pvy bigint[]; h_qvx bigint[]; h_qvy bigint[]; h_ax double precision[]; h_ay double precision[];
  h_bx double precision[]; h_by double precision[]; h_a text[]; h_b text[];
  l_x double precision[]; l_y double precision[]; l_vx bigint[]; l_vy bigint[]; l_id text[]; l_k0 integer[]; v_kind jsonb := '{}';
  r_x double precision[]; r_y double precision[]; r_w double precision[]; r_h double precision[];
  v_key text; v_cache jsonb; v_rows jsonb; v_c6 integer;
BEGIN
  IF p_level < 3 OR coalesce(p_what, 0) = 0 THEN RETURN; END IF;
  -- the battle grid asks for the same ground many times in one read or walk (the road squares, the fords, the water
  -- under them, a run of a walk; step 11), so a small block of it (up to two District cells each way) is answered
  -- from whole District cells, each worked out once and kept for the rest of the transaction (rpg.roads): a block
  -- that is not one District cell is the stretches of the cells it touches (a few more than reach the block itself,
  -- which no reader minds: each looks at the lines). A bigger block (the roads a walk plans with) is worked out as
  -- asked.
  IF p_level = 7 THEN
    SELECT l.cell INTO v_c6 FROM public.rpg_map_ladder() l WHERE l.level = 6;
    IF p_cols > 2 * v_c6 OR p_rows > 2 * v_c6 THEN
      v_c6 := NULL;
    ELSIF p_cols <> v_c6 OR p_rows <> v_c6 OR mod(mod(p_x0, v_c6) + v_c6, v_c6) <> 0 OR mod(mod(p_y0, v_c6) + v_c6, v_c6) <> 0 THEN
      RETURN QUERY
        SELECT DISTINCT ON (least(r.a, r.b), greatest(r.a, r.b)) r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b
          FROM generate_series(floor(p_x0::numeric / v_c6)::integer, floor((p_x0 + p_cols - 1)::numeric / v_c6)::integer) AS gx
         CROSS JOIN generate_series(floor(p_y0::numeric / v_c6)::integer, floor((p_y0 + p_rows - 1)::numeric / v_c6)::integer) AS gy
         CROSS JOIN LATERAL public.rpg_map_roads(7, gx * v_c6, gy * v_c6, v_c6, v_c6, p_what, p_towns, p_pad) r
         ORDER BY least(r.a, r.b), greatest(r.a, r.b), r.class;
      RETURN;
    END IF;
    IF v_c6 IS NOT NULL THEN
      v_key := p_x0 || ':' || p_y0 || ':' || p_what || ':' || coalesce(p_pad, 0) || ':' || md5(coalesce(p_towns::text, ''));
      v_cache := coalesce(nullif(current_setting('rpg.roads', true), ''), '{}')::jsonb;
      v_rows := v_cache -> v_key;
      IF v_rows IS NOT NULL THEN
        RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::double precision, (e.v ->> 2)::double precision, (e.v ->> 3)::double precision, (e.v ->> 4)::double precision, e.v ->> 5, e.v ->> 6
                       FROM jsonb_array_elements(v_rows) AS e(v);
        RETURN;
      END IF;
    END IF;
  END IF;
  SELECT * INTO c FROM public.rpg_map_lattice();
  SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  SELECT l.cell INTO v_c4 FROM public.rpg_map_ladder() l WHERE l.level = 4;
  v_k := c.lt / v_c4;
  SELECT s.value INTO v_high FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_penalty_high';
  SELECT coalesce(p_pad, 0) + max(s.value) / 2 INTO v_pad FROM public.rpg_settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width');
  -- the block with its margin, where a line of road must reach; and grown by the farthest a road wanders, where the
  -- straight line between the ends of a stretch must come for the stretch to be looked at
  t_x0 := p_x0::double precision * v_cell - v_pad; t_x1 := (p_x0 + p_cols)::double precision * v_cell + v_pad;
  t_y0 := p_y0::double precision * v_cell - v_pad; t_y1 := (p_y0 + p_rows)::double precision * v_cell + v_pad;
  v_far := public.rpg_map_road_swing();
  v_x0 := t_x0 - v_far; v_x1 := t_x1 + v_far; v_y0 := t_y0 - v_far; v_y1 := t_y1 + v_far;
  -- the block itself, without the margin: the sites p_towns speaks for
  v_bx0 := p_x0::bigint * v_cell; v_bx1 := (p_x0 + p_cols)::bigint * v_cell; v_by0 := p_y0::bigint * v_cell; v_by1 := (p_y0 + p_rows)::bigint * v_cell;
  SELECT s.value INTO v_cs FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_city_share';
  SELECT s.value INTO v_ts FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_share';
  -- the places no road crosses: ground rougher than a road
  SELECT array_agg(p.place_x::double precision), array_agg(p.place_y::double precision), array_agg(p.place_w::double precision), array_agg(p.place_h::double precision)
    INTO r_x, r_y, r_w, r_h
    FROM public.rpg_creatures p
   WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL AND p.place_penalty > v_high;

  -- highways: city to neighbouring city, through the town site of every town square on the way
  IF p_what & 1 = 1 THEN
    WITH bx AS (SELECT floor(v_x0 / c.lc)::bigint AS cxa, floor((v_x1 - 1) / c.lc)::bigint AS cxb,
                       greatest(floor(v_y0 / c.lc)::bigint, 0) AS cya, least(floor((v_y1 - 1) / c.lc)::bigint, c.down / c.lc - 1) AS cyb,
                       floor(v_x0 / c.lt)::bigint AS txa, floor((v_x1 - 1) / c.lt)::bigint AS txb,
                       floor(v_y0 / c.lt)::bigint AS tya, floor((v_y1 - 1) / c.lt)::bigint AS tyb),
         -- where the city of every city square near the block would stand
         cs AS MATERIALIZED (
           SELECT a AS cx, b AS cy, t.tx, t.ty, h.vx, h.vy, x.x::double precision AS x, x.y::double precision AS y
             FROM bx CROSS JOIN LATERAL generate_series(bx.cxa - 1, bx.cxb + 1) AS a
            CROSS JOIN LATERAL generate_series(greatest(bx.cya - 1, 0), least(bx.cyb + 1, c.down / c.lc - 1)) AS b
            CROSS JOIN LATERAL public.rpg_map_city(a, b, c.seed, c.nt, c.ac) t
            CROSS JOIN LATERAL public.rpg_map_hub(t.tx, t.ty, c.seed, c.nv, c.at) h
            CROSS JOIN LATERAL public.rpg_map_site(h.vx, h.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x),
         -- neighbouring city squares, each pair once, near the block, with no other city inside the circle across them
         pr AS MATERIALIZED (
           SELECT p.tx AS ptx, p.ty AS pty, p.vx AS pvx, p.vy AS pvy, q.tx AS qtx, q.ty AS qty, q.vx AS qvx, q.vy AS qvy
             FROM bx CROSS JOIN cs p
             JOIN cs q ON (q.cx - p.cx, q.cy - p.cy) IN ((1::bigint, 0::bigint), (0, 1), (1, 1), (-1, 1))
            WHERE least(p.cx, q.cx) <= bx.cxb AND greatest(p.cx, q.cx) >= bx.cxa AND least(p.cy, q.cy) <= bx.cyb AND greatest(p.cy, q.cy) >= bx.cya
              -- side by side always; corner to corner across a square of four only when its two other corners stand
              -- outside the circle across the two (so at most one of its two diagonals, and never across a corner)
              AND (q.cx - p.cx = 0 OR q.cy - p.cy = 0
                   OR NOT EXISTS (SELECT 1 FROM cs o
                                   WHERE ((o.cx = q.cx AND o.cy = p.cy) OR (o.cx = p.cx AND o.cy = q.cy))
                                     AND power(o.x - (p.x + q.x) / 2, 2) + power(o.y - (p.y + q.y) / 2, 2) < (power(p.x - q.x, 2) + power(p.y - q.y, 2)) / 4))),
         -- the town squares a highway runs through: n steps from the square of the first city to that of the second, each to a
         -- square next to the last, as near the straight line as squares go
         st AS MATERIALIZED (
           SELECT pr.pvx, pr.pvy, pr.qvx, pr.qvy, i,
                  pr.ptx + floor((2::numeric * i * (pr.qtx - pr.ptx) + nn.n) / (2 * nn.n))::bigint AS sx,
                  pr.pty + floor((2::numeric * i * (pr.qty - pr.pty) + nn.n) / (2 * nn.n))::bigint AS sy
             FROM pr CROSS JOIN LATERAL (SELECT greatest(abs(pr.qtx - pr.ptx), abs(pr.qty - pr.pty)) AS n) nn
            CROSS JOIN LATERAL generate_series(0, nn.n) AS i),
         -- the stretches between one step and the next whose two squares come near the block
         lg AS MATERIALIZED (
           SELECT s.pvx, s.pvy, s.qvx, s.qvy, s.sx AS atx, s.sy AS aty, n.sx AS btx, n.sy AS bty
             FROM st s JOIN st n ON n.pvx = s.pvx AND n.pvy = s.pvy AND n.qvx = s.qvx AND n.qvy = s.qvy AND n.i = s.i + 1
            CROSS JOIN bx
            WHERE least(s.sx, n.sx) <= bx.txb AND greatest(s.sx, n.sx) >= bx.txa AND least(s.sy, n.sy) <= bx.tyb AND greatest(s.sy, n.sy) >= bx.tya),
         hx AS MATERIALIZED (
           SELECT q.tx, q.ty, x.vw, h.vy, x.x::double precision AS x, x.y::double precision AS y
             FROM (SELECT lg.atx AS tx, lg.aty AS ty FROM lg UNION SELECT lg.btx, lg.bty FROM lg) q
            CROSS JOIN LATERAL public.rpg_map_hub(q.tx, q.ty, c.seed, c.nv, c.at) h
            CROSS JOIN LATERAL public.rpg_map_site(h.vx, h.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x)
    SELECT array_agg(lg.pvx), array_agg(lg.pvy), array_agg(lg.qvx), array_agg(lg.qvy),
           array_agg(a.x), array_agg(a.y), array_agg(b.x), array_agg(b.y),
           array_agg('site-' || a.vw || '-' || a.vy), array_agg('site-' || b.vw || '-' || b.vy)
      INTO h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b
      FROM lg JOIN hx a ON a.tx = lg.atx AND a.ty = lg.aty JOIN hx b ON b.tx = lg.btx AND b.ty = lg.bty
     WHERE public.rpg_seg_box(a.x, a.y, b.x, b.y, v_x0, v_y0, v_x1, v_y1);
    -- of those, the stretches whose line may reach the block
    IF h_pvx IS NOT NULL THEN
      v_keep := public.rpg_map_road_reaches(array_fill(1, ARRAY[cardinality(h_a)]), h_ax, h_ay, h_bx, h_by, h_a, h_b, t_x0, t_y0, t_x1, t_y1);
      SELECT array_agg(h.pvx ORDER BY h.i), array_agg(h.pvy ORDER BY h.i), array_agg(h.qvx ORDER BY h.i), array_agg(h.qvy ORDER BY h.i),
             array_agg(h.ax ORDER BY h.i), array_agg(h.ay ORDER BY h.i), array_agg(h.bx ORDER BY h.i), array_agg(h.by ORDER BY h.i), array_agg(h.a ORDER BY h.i), array_agg(h.b ORDER BY h.i)
        INTO h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b
        FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b) WITH ORDINALITY AS h(pvx, pvy, qvx, qvy, ax, ay, bx, by, a, b, i)
       WHERE h.i = ANY (v_keep);
    END IF;
    IF h_pvx IS NOT NULL THEN
      -- only between two cities that are there: first what is known without reading the map (a roll that makes no city
      -- even on the best ground; a site inside the block, from p_towns), then the other ends of what is left
      WITH cu AS (SELECT DISTINCT u.vx, u.vy FROM unnest(h_pvx || h_qvx, h_pvy || h_qvy) AS u(vx, vy))
      SELECT coalesce(jsonb_object_agg(cu.vx || ',' || cu.vy,
                        CASE WHEN ((public.rpg_map_site_rolls(x.vw, cu.vy, c.seed))[1] - 0.5) / 100 >= v_cs THEN 'no'
                             ELSE coalesce(p_towns ->> ('site-' || x.vw || '-' || cu.vy), 'no') END)
                      FILTER (WHERE ((public.rpg_map_site_rolls(x.vw, cu.vy, c.seed))[1] - 0.5) / 100 >= v_cs
                                 OR (p_towns IS NOT NULL AND x.x >= v_bx0 AND x.x < v_bx1 AND x.y >= v_by0 AND x.y < v_by1)), '{}')
        INTO v_ek
        FROM cu CROSS JOIN LATERAL public.rpg_map_site(cu.vx, cu.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x;
      WITH un AS (SELECT DISTINCT q.vx, q.vy
                    FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy) AS h(pvx, pvy, qvx, qvy)
                   CROSS JOIN LATERAL (VALUES (h.pvx, h.pvy), (h.qvx, h.qvy)) AS q(vx, vy)
                   WHERE coalesce(v_ek ->> (h.pvx || ',' || h.pvy), 'city') = 'city' AND coalesce(v_ek ->> (h.qvx || ',' || h.qvy), 'city') = 'city'
                     AND NOT v_ek ? (q.vx || ',' || q.vy)),
           ck AS (SELECT array_agg(un.vx) AS vx, array_agg(un.vy) AS vy FROM un HAVING count(*) > 0)
      SELECT v_ek || coalesce(jsonb_object_agg(t.vx || ',' || t.vy, coalesce(t.kind, 'no')), '{}') INTO v_ek
        FROM ck CROSS JOIN LATERAL public.rpg_map_town_at(ck.vx, ck.vy, NULL, NULL, true) t;
      SELECT o_cls || coalesce(array_agg(1), '{}'), o_ax || coalesce(array_agg(h.ax), '{}'), o_ay || coalesce(array_agg(h.ay), '{}'),
             o_bx || coalesce(array_agg(h.bx), '{}'), o_by || coalesce(array_agg(h.by), '{}'), o_a || coalesce(array_agg(h.a), '{}'), o_b || coalesce(array_agg(h.b), '{}')
        INTO o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b
        FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b) AS h(pvx, pvy, qvx, qvy, ax, ay, bx, by, a, b)
       WHERE v_ek ->> (h.pvx || ',' || h.pvy) = 'city' AND v_ek ->> (h.qvx || ',' || h.qvy) = 'city';
    END IF;
  END IF;

  -- roads: town to neighbouring town, straight between their sites
  IF p_what & 2 = 2 AND p_level >= 4 THEN
    WITH bx AS (SELECT floor(v_x0 / c.lt)::bigint AS txa, floor((v_x1 - 1) / c.lt)::bigint AS txb,
                       greatest(floor(v_y0 / c.lt)::bigint, 0) AS tya, least(floor((v_y1 - 1) / c.lt)::bigint, c.down / c.lt - 1) AS tyb),
         hs AS MATERIALIZED (
           SELECT a AS tx, b AS ty, h.vx, h.vy, x.vw, x.x::double precision AS x, x.y::double precision AS y
             FROM bx CROSS JOIN LATERAL generate_series(bx.txa - 1, bx.txb + 1) AS a
            CROSS JOIN LATERAL generate_series(greatest(bx.tya - 1, 0), least(bx.tyb + 1, c.down / c.lt - 1)) AS b
            CROSS JOIN LATERAL public.rpg_map_hub(a, b, c.seed, c.nv, c.at) h
            CROSS JOIN LATERAL public.rpg_map_site(h.vx, h.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x),
         pr AS MATERIALIZED (
           SELECT p.vx AS pvx, p.vy AS pvy, q.vx AS qvx, q.vy AS qvy, p.x AS ax, p.y AS ay, q.x AS bx, q.y AS by,
                  'site-' || p.vw || '-' || p.vy AS a, 'site-' || q.vw || '-' || q.vy AS b
             FROM bx CROSS JOIN hs p
             JOIN hs q ON (q.tx - p.tx, q.ty - p.ty) IN ((1::bigint, 0::bigint), (0, 1), (1, 1), (-1, 1))
            WHERE p.tx BETWEEN bx.txa - 1 AND bx.txb + 1 AND p.ty BETWEEN bx.tya - 1 AND bx.tyb + 1
              AND q.tx BETWEEN bx.txa - 1 AND bx.txb + 1 AND q.ty BETWEEN bx.tya - 1 AND bx.tyb + 1
              AND public.rpg_seg_box(p.x, p.y, q.x, q.y, v_x0, v_y0, v_x1, v_y1)
              AND (q.tx - p.tx = 0 OR q.ty - p.ty = 0
                   OR NOT EXISTS (SELECT 1 FROM hs o
                                   WHERE ((o.tx = q.tx AND o.ty = p.ty) OR (o.tx = p.tx AND o.ty = q.ty))
                                     AND power(o.x - (p.x + q.x) / 2, 2) + power(o.y - (p.y + q.y) / 2, 2) < (power(p.x - q.x, 2) + power(p.y - q.y, 2)) / 4)))
    SELECT array_agg(pr.pvx), array_agg(pr.pvy), array_agg(pr.qvx), array_agg(pr.qvy), array_agg(pr.ax), array_agg(pr.ay),
           array_agg(pr.bx), array_agg(pr.by), array_agg(pr.a), array_agg(pr.b)
      INTO h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b
      FROM pr;
    -- of those, the stretches whose line may reach the block
    IF h_pvx IS NOT NULL THEN
      v_keep := public.rpg_map_road_reaches(array_fill(2, ARRAY[cardinality(h_a)]), h_ax, h_ay, h_bx, h_by, h_a, h_b, t_x0, t_y0, t_x1, t_y1);
      SELECT array_agg(h.pvx ORDER BY h.i), array_agg(h.pvy ORDER BY h.i), array_agg(h.qvx ORDER BY h.i), array_agg(h.qvy ORDER BY h.i),
             array_agg(h.ax ORDER BY h.i), array_agg(h.ay ORDER BY h.i), array_agg(h.bx ORDER BY h.i), array_agg(h.by ORDER BY h.i), array_agg(h.a ORDER BY h.i), array_agg(h.b ORDER BY h.i)
        INTO h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b
        FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b) WITH ORDINALITY AS h(pvx, pvy, qvx, qvy, ax, ay, bx, by, a, b, i)
       WHERE h.i = ANY (v_keep);
    END IF;
    IF h_pvx IS NOT NULL THEN
      -- only between two towns or cities that are there, known first as for the highways
      WITH cu AS (SELECT DISTINCT u.vx, u.vy FROM unnest(h_pvx || h_qvx, h_pvy || h_qvy) AS u(vx, vy)),
           cr AS (SELECT cu.vx, cu.vy, x.vw, x.x, x.y,
                         NOT (x.city AND (r.r[1] - 0.5) / 100 < v_cs) AND NOT (x.town AND (r.r[2] - 0.5) / 100 < v_ts) AS none,
                         p_towns IS NOT NULL AND x.x >= v_bx0 AND x.x < v_bx1 AND x.y >= v_by0 AND x.y < v_by1 AS known
                    FROM cu CROSS JOIN LATERAL public.rpg_map_site(cu.vx, cu.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
                   CROSS JOIN LATERAL (SELECT public.rpg_map_site_rolls(x.vw, cu.vy, c.seed) AS r) r)
      SELECT coalesce(jsonb_object_agg(cr.vx || ',' || cr.vy,
                        CASE WHEN cr.none THEN 'no' WHEN p_towns ->> ('site-' || cr.vw || '-' || cr.vy) IN ('town', 'city') THEN 'town' ELSE 'no' END)
                      FILTER (WHERE cr.none OR cr.known), '{}')
        INTO v_ek FROM cr;
      WITH un AS (SELECT DISTINCT q.vx, q.vy
                    FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy) AS h(pvx, pvy, qvx, qvy)
                   CROSS JOIN LATERAL (VALUES (h.pvx, h.pvy), (h.qvx, h.qvy)) AS q(vx, vy)
                   WHERE coalesce(v_ek ->> (h.pvx || ',' || h.pvy), 'town') = 'town' AND coalesce(v_ek ->> (h.qvx || ',' || h.qvy), 'town') = 'town'
                     AND NOT v_ek ? (q.vx || ',' || q.vy)),
           ck AS (SELECT array_agg(un.vx) AS vx, array_agg(un.vy) AS vy FROM un HAVING count(*) > 0)
      SELECT v_ek || coalesce(jsonb_object_agg(t.vx || ',' || t.vy, CASE WHEN t.kind IN ('town', 'city') THEN 'town' ELSE 'no' END), '{}') INTO v_ek
        FROM ck CROSS JOIN LATERAL public.rpg_map_town_at(ck.vx, ck.vy, NULL, NULL, false) t;
      SELECT o_cls || coalesce(array_agg(2), '{}'), o_ax || coalesce(array_agg(h.ax), '{}'), o_ay || coalesce(array_agg(h.ay), '{}'),
             o_bx || coalesce(array_agg(h.bx), '{}'), o_by || coalesce(array_agg(h.by), '{}'), o_a || coalesce(array_agg(h.a), '{}'), o_b || coalesce(array_agg(h.b), '{}')
        INTO o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b
        FROM unnest(h_pvx, h_pvy, h_qvx, h_qvy, h_ax, h_ay, h_bx, h_by, h_a, h_b) AS h(pvx, pvy, qvx, qvy, ax, ay, bx, by, a, b)
       WHERE v_ek ->> (h.pvx || ',' || h.pvy) = 'town' AND v_ek ->> (h.qvx || ',' || h.qvy) = 'town';
    END IF;
  END IF;

  -- lanes: each village to the next village on its way to market, inside its town square
  IF p_what & 4 = 4 AND p_level >= 4 THEN
    -- the places a lane could start from and come near the block, whoever lives where: a site (or a village place card)
    -- with a stretch to one of the sites on its way to market that comes near the block
    WITH bx AS (SELECT floor(v_x0 / c.lt)::bigint AS txa, floor((v_x1 - 1) / c.lt)::bigint AS txb,
                       greatest(floor(v_y0 / c.lt)::bigint, 0) AS tya, least(floor((v_y1 - 1) / c.lt)::bigint, c.down / c.lt - 1) AS tyb),
         ss AS MATERIALIZED (
           SELECT v AS vx, w AS vy, x.x::double precision AS x, x.y::double precision AS y, h.vx AS hx, h.vy AS hy
             FROM bx CROSS JOIN LATERAL generate_series(bx.txa, bx.txb) AS a
            CROSS JOIN LATERAL generate_series(bx.tya, bx.tyb) AS b
            CROSS JOIN LATERAL public.rpg_map_hub(a, b, c.seed, c.nv, c.at) h
            CROSS JOIN LATERAL generate_series(a * c.nv, a * c.nv + c.nv - 1) AS v
            CROSS JOIN LATERAL generate_series(b * c.nv, b * c.nv + c.nv - 1) AS w
            CROSS JOIN LATERAL public.rpg_map_site(v, w, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x),
         pc AS (
           SELECT m.x, m.y, ss.hx, ss.hy, ss.vx, ss.vy, p.id::text AS id
             FROM public.rpg_creatures p
            CROSS JOIN LATERAL (SELECT p.place_x + c.world * floor(((v_x0 + v_x1) / 2 - p.place_x) / c.world + 0.5) AS x,
                                       p.place_y::double precision AS y) m
             JOIN ss ON ss.vx = floor(m.x / c.lv)::bigint AND ss.vy = floor(m.y / c.lv)::bigint
            WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL
              AND p.place_penalty IS NOT NULL AND p.place_icon IN ('village', 'town', 'city')),
         way AS (
           SELECT s.x, s.y, s.vx, s.vy, s.hx, s.hy, NULL::text AS id, 1 AS k0 FROM ss s
           UNION ALL
           SELECT p.x, p.y, p.vx, p.vy, p.hx, p.hy, p.id, 0 FROM pc p),
         nr AS (
           SELECT DISTINCT w.x, w.y, w.vx, w.vy, w.id, w.k0, t.x AS tx, t.y AS ty,
                  coalesce(w.id, 'site-' || mod(mod(w.vx, c.av) + c.av, c.av) || '-' || w.vy) AS a, 'site-' || mod(mod(t.vx, c.av) + c.av, c.av) || '-' || t.vy AS b
             FROM way w
            CROSS JOIN LATERAL generate_series(w.k0, greatest(abs(w.hx - w.vx), abs(w.hy - w.vy))::integer) AS k
             JOIN ss t ON t.vx = w.vx + sign(w.hx - w.vx)::bigint * least(k, abs(w.hx - w.vx))
                      AND t.vy = w.vy + sign(w.hy - w.vy)::bigint * least(k, abs(w.hy - w.vy))
            WHERE public.rpg_seg_box(w.x, w.y, t.x, t.y, v_x0, v_y0, v_x1, v_y1))
    SELECT array_agg(nr.x), array_agg(nr.y), array_agg(nr.vx), array_agg(nr.vy), array_agg(nr.id), array_agg(nr.k0), array_agg(nr.tx), array_agg(nr.ty), array_agg(nr.a), array_agg(nr.b)
      INTO p_x, p_y, p_vx, p_vy, p_id, p_k0, p_tx, p_ty, p_a, p_b FROM nr;
    -- of those, the places with a stretch whose line may reach the block
    IF p_vx IS NOT NULL THEN
      v_keep := public.rpg_map_road_reaches(array_fill(3, ARRAY[cardinality(p_x)]), p_x, p_y, p_tx, p_ty, p_a, p_b, t_x0, t_y0, t_x1, t_y1);
      SELECT array_agg(q.x), array_agg(q.y), array_agg(q.vx), array_agg(q.vy), array_agg(q.id), array_agg(q.k0)
        INTO l_x, l_y, l_vx, l_vy, l_id, l_k0
        FROM (SELECT DISTINCT p.x, p.y, p.vx, p.vy, p.id, p.k0
                FROM unnest(p_x, p_y, p_vx, p_vy, p_id, p_k0) WITH ORDINALITY AS p(x, y, vx, vy, id, k0, i)
               WHERE p.i = ANY (v_keep)) q;
    END IF;
    IF l_vx IS NOT NULL THEN
      -- who lives at each site those lanes could start at or reach (the site itself and every site on its way): known
      -- from p_towns inside the block, else read (rpg_map_town_at)
      WITH nd AS (SELECT n.vx, n.vy, n.k0, h.vx AS hx, h.vy AS hy
                    FROM unnest(l_vx, l_vy, l_k0) AS n(vx, vy, k0)
                   CROSS JOIN LATERAL public.rpg_map_hub(floor(n.vx::double precision / c.nv)::bigint, floor(n.vy::double precision / c.nv)::bigint, c.seed, c.nv, c.at) h),
           st AS (SELECT q.vx, q.vy
                    FROM nd CROSS JOIN LATERAL generate_series(nd.k0, greatest(abs(nd.hx - nd.vx), abs(nd.hy - nd.vy))::integer) AS k
                   CROSS JOIN LATERAL (SELECT nd.vx + sign(nd.hx - nd.vx)::bigint * least(k, abs(nd.hx - nd.vx)) AS vx,
                                              nd.vy + sign(nd.hy - nd.vy)::bigint * least(k, abs(nd.hy - nd.vy)) AS vy) q
                  UNION
                  SELECT nd.vx, nd.vy FROM nd WHERE nd.k0 = 1),
           sx AS (SELECT st.vx, st.vy, 'site-' || x.vw || '-' || st.vy AS id,
                         p_towns IS NOT NULL AND x.x >= v_bx0 AND x.x < v_bx1 AND x.y >= v_by0 AND x.y < v_by1 AS known
                    FROM st CROSS JOIN LATERAL public.rpg_map_site(st.vx, st.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x)
      SELECT coalesce(jsonb_object_agg(sx.vx || ',' || sx.vy, coalesce(p_towns ->> sx.id, 'no')) FILTER (WHERE sx.known), '{}'),
             array_agg(sx.vx) FILTER (WHERE NOT sx.known), array_agg(sx.vy) FILTER (WHERE NOT sx.known)
        INTO v_kind, h_pvx, h_pvy FROM sx;
      IF h_pvx IS NOT NULL THEN
        SELECT v_kind || coalesce(jsonb_object_agg(t.vx || ',' || t.vy, coalesce(t.kind, 'no')), '{}') INTO v_kind
          FROM public.rpg_map_town_at(h_pvx, h_pvy, NULL, NULL, false, true) t;
      END IF;
      -- the lane from each place that has people to the first site on its way that has people
      WITH nd AS (SELECT n.x, n.y, n.vx, n.vy, n.id, n.k0, h.vx AS hx, h.vy AS hy
                    FROM unnest(l_x, l_y, l_vx, l_vy, l_id, l_k0) AS n(x, y, vx, vy, id, k0)
                   CROSS JOIN LATERAL public.rpg_map_hub(floor(n.vx::double precision / c.nv)::bigint, floor(n.vy::double precision / c.nv)::bigint, c.seed, c.nv, c.at) h
                   WHERE n.k0 = 0 OR coalesce(v_kind ->> (n.vx || ',' || n.vy), 'no') <> 'no'),
           ln AS (
             SELECT nd.x AS ax, nd.y AS ay, t.x AS bx, t.y AS by,
                    coalesce(nd.id, 'site-' || mod(mod(nd.vx, c.av) + c.av, c.av) || '-' || nd.vy) AS a, 'site-' || t.vw || '-' || t.vy AS b
               FROM nd
              CROSS JOIN LATERAL (SELECT q.x::double precision AS x, q.y::double precision AS y, q.vw, k.vy
                                    FROM generate_series(nd.k0, greatest(abs(nd.hx - nd.vx), abs(nd.hy - nd.vy))::integer) AS kk
                                   CROSS JOIN LATERAL (SELECT nd.vx + sign(nd.hx - nd.vx)::bigint * least(kk, abs(nd.hx - nd.vx)) AS vx,
                                                              nd.vy + sign(nd.hy - nd.vy)::bigint * least(kk, abs(nd.hy - nd.vy)) AS vy) k
                                   CROSS JOIN LATERAL public.rpg_map_site(k.vx, k.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) q
                                   WHERE coalesce(v_kind ->> (k.vx || ',' || k.vy), 'no') <> 'no'
                                   ORDER BY kk LIMIT 1) t)
      SELECT array_agg(ln.ax), array_agg(ln.ay), array_agg(ln.bx), array_agg(ln.by), array_agg(ln.a), array_agg(ln.b)
        INTO p_x, p_y, p_tx, p_ty, p_a, p_b
        FROM ln
       WHERE public.rpg_seg_box(ln.ax, ln.ay, ln.bx, ln.by, v_x0, v_y0, v_x1, v_y1);
      -- of those, the lanes whose line may reach the block
      IF p_x IS NOT NULL THEN
        v_keep := public.rpg_map_road_reaches(array_fill(3, ARRAY[cardinality(p_x)]), p_x, p_y, p_tx, p_ty, p_a, p_b, t_x0, t_y0, t_x1, t_y1);
        SELECT o_cls || coalesce(array_agg(3), '{}'), o_ax || coalesce(array_agg(q.ax), '{}'), o_ay || coalesce(array_agg(q.ay), '{}'),
               o_bx || coalesce(array_agg(q.bx), '{}'), o_by || coalesce(array_agg(q.by), '{}'), o_a || coalesce(array_agg(q.a), '{}'), o_b || coalesce(array_agg(q.b), '{}')
          INTO o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b
          FROM unnest(p_x, p_y, p_tx, p_ty, p_a, p_b) WITH ORDINALITY AS q(ax, ay, bx, by, a, b, i)
         WHERE q.i = ANY (v_keep);
      END IF;
    END IF;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_array(q.cls, q.ax, q.ay, q.bx, q.by, q.a, q.b)), '[]'::jsonb)
    INTO v_rows
    FROM (SELECT DISTINCT ON (least(o.a, o.b), greatest(o.a, o.b)) o.cls, o.ax, o.ay, o.bx, o.by, o.a, o.b
            FROM unnest(o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b) AS o(cls, ax, ay, bx, by, a, b)
           WHERE NOT EXISTS (SELECT 1 FROM unnest(r_x, r_y, r_w, r_h) AS r(x, y, w, h)
                              WHERE public.rpg_map_seg_oval(o.ax, o.ay, o.bx, o.by, r.x, r.y, r.w, r.h, c.world::double precision))
           ORDER BY least(o.a, o.b), greatest(o.a, o.b), o.cls) q;
  IF v_key IS NOT NULL THEN PERFORM set_config('rpg.roads', jsonb_set(v_cache, ARRAY[v_key], v_rows)::text, true); END IF;
  RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::double precision, (e.v ->> 2)::double precision, (e.v ->> 3)::double precision, (e.v ->> 4)::double precision, e.v ->> 5, e.v ->> 6
                 FROM jsonb_array_elements(v_rows) AS e(v);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, class integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block that a road runs over (step 8b): the middle of the cell lies within half the width of the road
-- (map_road_<size>_width) of the line of a stretch of road (rpg_map_roads, the one home of where roads run; the line
-- wanders, step 10b: rpg_map_road_lines, read in full where it comes near the block). Only the battle grid has cells
-- this small (a highway is 6.5 m wide, a square 1.1 m); rpg_map_cells makes them road ground. The stretches are asked
-- for with a margin of 12 squares, the same ask as the fords of the block make (rpg_map_ford_cells), so the two share
-- one answer (step 11).
-- class = the biggest road there (1 highway, 2 road, 3 lane).
WITH lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     w AS (SELECT substr(s.key, 10, 1)::integer AS class, s.value::double precision / 2 AS half FROM public.rpg_settings s
            WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width')),
     lg AS MATERIALIZED (
       SELECT row_number() OVER () AS n, r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b, w.half
         FROM public.rpg_map_roads(p_level, p_x0, p_y0, p_cols, p_rows, 7, NULL, 12) r JOIN w ON w.class = r.class),
     la AS (SELECT array_agg(lg.class ORDER BY lg.n) AS class, array_agg(lg.half ORDER BY lg.n) AS half, array_agg(lg.ax ORDER BY lg.n) AS ax, array_agg(lg.ay ORDER BY lg.n) AS ay,
                   array_agg(lg.bx ORDER BY lg.n) AS bx, array_agg(lg.by ORDER BY lg.n) AS by, array_agg(lg.a ORDER BY lg.n) AS a, array_agg(lg.b ORDER BY lg.n) AS b,
                   max(lg.half) AS wide
              FROM lg HAVING count(*) > 0),
     -- the points of every line where it comes within half the widest road of the block
     lp AS MATERIALIZED (
       SELECT p.i, p.n, p.x, p.y, la.class[p.i] AS class, la.half[p.i] AS half
         FROM la CROSS JOIN lad
        CROSS JOIN LATERAL public.rpg_map_road_lines(la.class, la.ax, la.ay, la.bx, la.by, la.a, la.b, lad.cell, NULL,
                                                     p_x0 * lad.cell - la.wide, p_y0 * lad.cell - la.wide, (p_x0 + p_cols) * lad.cell + la.wide, (p_y0 + p_rows) * lad.cell + la.wide) p),
     -- each piece of line from one point to the next
     sg AS (SELECT a.class, a.half, a.x AS ax, a.y AS ay, b.x AS bx, b.y AS by FROM lp a JOIN lp b ON b.i = a.i AND b.n = a.n + 1)
SELECT gx, gy, min(sg.class)
  FROM sg CROSS JOIN lad
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor((least(sg.ax, sg.bx) - sg.half) / lad.cell)::integer),
                                    least(p_x0 + p_cols - 1, floor((greatest(sg.ax, sg.bx) + sg.half) / lad.cell)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((least(sg.ay, sg.by) - sg.half) / lad.cell)::integer),
                                    least(p_y0 + p_rows - 1, floor((greatest(sg.ay, sg.by) + sg.half) / lad.cell)::integer)) AS gy
 -- how far the middle of the cell lies from the piece: from its nearest point
 CROSS JOIN LATERAL (SELECT (gx + 0.5) * lad.cell - sg.ax AS px, (gy + 0.5) * lad.cell - sg.ay AS py, sg.bx - sg.ax AS dx, sg.by - sg.ay AS dy) v
 CROSS JOIN LATERAL (SELECT CASE WHEN v.dx * v.dx + v.dy * v.dy = 0 THEN 0
                                 ELSE least(greatest((v.px * v.dx + v.py * v.dy) / (v.dx * v.dx + v.dy * v.dy), 0), 1) END AS t) t
 WHERE power(v.px - t.t * v.dx, 2) + power(v.py - t.t * v.dy, 2) <= sg.half * sg.half
 GROUP BY gx, gy;
$function$;

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
     dep AS (SELECT rv.x, rv.y, rv.depth, rv.line, rv.current FROM rv
             UNION ALL
             SELECT lk.x, lk.y, lk.depth, NULL::integer,
                    CASE WHEN lk.depth > 0 THEN (SELECT st.value FROM st WHERE st.key = 'map_still_current')::double precision ELSE 0 END
               FROM lk)
SELECT b.x, b.y, coalesce(max(dep.depth), 0), coalesce(min(dep.line), 0), coalesce(max(dep.current), 0)
  FROM (SELECT gx AS x, gy AS y FROM generate_series(p_x0, p_x0 + p_cols - 1) gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) gy) b
  LEFT JOIN dep ON dep.x = b.x AND dep.y = b.y
 GROUP BY b.x, b.y;
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
--              a road meets a river or a lake it crosses it: by a bridge (road, ahead of the water) or, where the
--              stretch fords that river (step 11; rpg_map_ford_cells), through the water, which is knee-deep there
--              (water, waded); the sea stops it. Coarser grids draw roads as lines instead.
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
  LEFT JOIN fd ON fd.x = g.gx AND fd.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim, tc.x, rd.x, fd.x
 ORDER BY g.gy, g.gx;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view_block(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
-- towns = the villages, towns and cities the read shows (step 8; rpg_map_towns): the Country grid its cities and the
-- Region grid all three, each a mark in the cell its middle stands in (its id among the marks of that cell); on the City
-- grid and finer the cells of the ground of each (rpg_map_town_cells), which come as kind place with place = its id,
-- so they are drawn and named like a place with ground. A grid drawn fine carries them in its detail the same way.
-- Each is told as rpg_map_town_entry tells it; the Region grid lists its towns and cities.
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
-- roll] (rpg_map_building_cells); its cost is the climb's. The kids login sees a house once a cell of it is found.
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
  v_rivs      jsonb;
  v_drivs     jsonb;
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
    -- a whole grid: the world, or the grid inside one cell of the grid above
    IF v_cols <> v_l.cols OR v_rows <> v_l.rows OR v_x0 < 0 OR mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0 THEN
      RAISE EXCEPTION 'that grid is off the map';
    END IF;
    v_x := v_x0 / v_cols;
    v_y := v_y0 / v_rows;
  END IF;
  IF p_place IS NULL AND v_l.level > 1 THEN
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
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
  -- the cells, read once for the villages, towns and cities on them (step 8) and for the picture
  WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows)),
       -- the kinds of the cells of a Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (3, 4)),
       -- the villages, towns and cities marked on this grid (the Country grid its cities, the Region grid all three),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT kj.k FROM kj)) t
          WHERE v_l.level IN (3, 4) AND t.kind IS NOT NULL),
       tm AS (SELECT floor(tw.x::double precision / v_l.cell)::integer AS x, floor(tw.y::double precision / v_l.cell)::integer AS y,
                     jsonb_agg(tw.id ORDER BY tw.id) AS ids
                FROM tw GROUP BY 1, 2),
       -- the words for their streets, once
       gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
       -- the City grid and finer: the cells of their ground
       tg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) t WHERE v_l.level >= 5),
       -- the battle grid: the squares a house stands on (step 8c), where a village, town, city or place is
       hb AS MATERIALIZED (SELECT b.* FROM public.rpg_map_building_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) b
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))),
       -- the rivers near every cell (rpg_map_rivers), read once: for the lines drawn and for the crossings (step 11),
       -- with a margin round the block where a crossing just outside it may still reach in
       rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) r),
       -- the battle grid: the water under the roads and the fords (step 11), where it has roads or water
       wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_flow(v_l.level, v_x0, v_y0, v_cols, v_rows) w
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       fd AS MATERIALIZED (SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif,
                CASE WHEN c.kind IN ('road', 'pass') AND wt.depth > 0 THEN 'bridge' WHEN c.kind = 'water' AND fd.x IS NOT NULL THEN 'ford' END AS cross
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
           LEFT JOIN fd ON fd.x = c.x AND fd.y = c.y
           LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
           LEFT JOIN public.rpg_map_steep(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
           LEFT JOIN (SELECT DISTINCT w.x, w.y
                        FROM unnest(v_known) AS n(id)
                       CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_cols, v_rows) w
                       WHERE NOT v_gm) kn ON kn.x = c.x AND kn.y = c.y
           LEFT JOIN tm ON tm.x = c.x AND tm.y = c.y
           LEFT JOIN tg ON tg.x = c.x AND tg.y = c.y
           LEFT JOIN hb ON hb.x = c.x AND hb.y = c.y
          CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
          -- the cell itself counted round the world, for a block that runs past the east or west end
          CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx)
  SELECT (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'x', cl.x - v_x0 + 1, 'y', cl.y - v_y0 + 1,
                   'name', public.rpg_square_name(cl.x - v_x0 + 1, cl.y - v_y0 + 1),
                   -- a cell of a village, town or city comes as a place, its place the settlement, so it is drawn and
                   -- named like a place with ground
                   'kind', CASE WHEN NOT cl.seen THEN 'unknown' WHEN cl.town IS NOT NULL THEN 'place' ELSE cl.kind END,
                   'place', CASE WHEN cl.seen THEN coalesce(cl.town, cl.place_id::text) END,
                   'marks', CASE WHEN cl.seen AND (cardinality(cl.marks) > 0 OR cl.towns IS NOT NULL) THEN to_jsonb(cl.marks) || coalesce(cl.towns, '[]'::jsonb) END,
                   'cost', CASE WHEN cl.seen THEN cl.penalty END,
                   'hard', CASE WHEN cl.seen AND (cl.penalty IS NOT NULL OR cl.kind = 'deep') AND cl.hard IS NOT NULL THEN least(floor(cl.hard * 10), 9)::integer END,
                   -- the battle grid's mountains and hills: how near the square is to the middle line of its chain, in
                   -- thousandths of a ground roll below it (0 on the line; rpg_map_blend part 1, the roll that makes them), so
                   -- the page can tell which way is uphill and draw the slope (Peter 2026-10-04: a mountain side)
                   'rise', CASE WHEN cl.seen AND cl.kind IN ('mountains', 'hills') AND cl.blend IS NOT NULL THEN round(-abs(cl.blend) * 1000)::integer END,
                   -- the battle grid's cliffs: how steep, in degrees (rpg_map_cliff_angle; step 7c), so the page draws the rock face
                   'cliff', CASE WHEN cl.seen AND cl.kind = 'mountains' THEN round(public.rpg_map_cliff_angle(cl.steep))::integer END,
                   -- a square a house stands on (step 8c): its wall or roof, the metres it climbs, how steep, the difficulty
                   'climb', CASE WHEN cl.seen AND cl.part IS NOT NULL
                                 THEN jsonb_build_array(cl.part, round(cl.climb_rise::numeric, 1), round(cl.climb_angle)::integer, cl.climb_dif) END,
                   'river', CASE WHEN cl.seen AND cl.line > 0 AND cl.kind NOT IN ('water', 'deep', 'sea')
                                 THEN jsonb_build_array(cl.line, round(cl.px * 1000)::integer, round(cl.py * 1000)::integer) END,
                   -- the battle grid: a bridge over the water, or a ford through it (step 11)
                   'cross', CASE WHEN cl.seen THEN cl.cross END,
                   'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || cl.wx::text || '-' || cl.y::text END,
                   'to', jsonb_build_array(cl.wx::bigint * v_l.cell + v_l.cell / 2 + 1, cl.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
                 ORDER BY cl.y, cl.x)
            FROM cl),
         -- the villages, towns and cities shown: a mark on a cell that is seen, or ground on one
         (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1,
                                                     v_l.level = 4 AND q.kind IN ('town', 'city'), q.ground)
                           ORDER BY q.n, q.name)
            FROM (SELECT tw.id, tw.kind, tw.name, tw.people, tw.x, tw.y, tw.r, array_position(ARRAY['city', 'town', 'village'], tw.kind) AS n, gt.g AS ground
                    FROM tw CROSS JOIN gt JOIN cl ON cl.x = floor(tw.x::double precision / v_l.cell)::integer AND cl.y = floor(tw.y::double precision / v_l.cell)::integer
                   WHERE cl.seen
                  UNION ALL
                  SELECT DISTINCT ON (tg.id) tg.id, tg.kind, tg.name, tg.people, tg.tx, tg.ty, tg.r, array_position(ARRAY['city', 'town', 'village'], tg.kind), gt.g
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
            FROM rva r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs;

  -- the houses of the battle grid (step 8c): every one with a square seen here, drawn whole as far as the grid goes
  IF v_l.level = 7 AND cardinality(v_hseen) > 0 THEN
    SELECT jsonb_agg(jsonb_build_object(
             'id', h.id, 'roof', h.roof,
             'x', round((h.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((h.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(h.ux * 1000)::integer, round(h.uy * 1000)::integer),
             'len', round(2 * h.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * h.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(h.eaves::numeric, 1), 'pitch', round(h.pitch)::integer, 'storeys', h.storeys) ORDER BY h.id)
      INTO v_houses
      FROM public.rpg_map_buildings(v_l.level, v_x0, v_y0, v_cols, v_rows) h
     WHERE h.id = ANY (v_hseen);
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
            WHERE v_l.level + 1 = 4 AND t.kind IS NOT NULL),
         dm AS (SELECT floor(dt.x::double precision / (v_l.cell / v_sub))::integer AS x, floor(dt.y::double precision / (v_l.cell / v_sub))::integer AS y,
                       jsonb_agg(dt.id ORDER BY dt.id) AS ids
                  FROM dt GROUP BY 1, 2),
         gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
         dg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) t WHERE v_l.level + 1 >= 5),
         rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub - v_rm, v_ry0, v_dc + 2 * v_rm, v_ry1 - v_ry0) r),
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
             LEFT JOIN dm ON dm.x = c.x AND dm.y = c.y
             LEFT JOIN dg ON dg.x = c.x AND dg.y = c.y),
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
                              'marks', (SELECT jsonb_object_agg((d.x - v_x0 * v_sub)::text || ',' || (d.y - v_y0 * v_sub)::text, to_jsonb(d.marks) || coalesce(d.towns, '[]'::jsonb))
                                          FROM d WHERE d.seen AND (cardinality(d.marks) > 0 OR d.towns IS NOT NULL))),
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
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width');
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
                 CROSS JOIN LATERAL (SELECT q.d, q.qu, q.qv,
                                            coalesce(least(CASE WHEN q.qu > floor(lr.u) + 1 THEN (floor(lr.u) + 1 - lr.u) / (q.qu - lr.u)
                                                                WHEN q.qu < floor(lr.u) THEN (floor(lr.u) - lr.u) / (q.qu - lr.u) END,
                                                           CASE WHEN q.qv > floor(lr.v) + 1 THEN (floor(lr.v) + 1 - lr.v) / (q.qv - lr.v)
                                                                WHEN q.qv < floor(lr.v) THEN (floor(lr.v) - lr.v) / (q.qv - lr.v) END), 1) AS t) e
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
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rv WHERE rv.x = g.x0 + floor(q.ox)::integer AND rv.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rv r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rv)),
         xs AS (
           SELECT cx.*, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1),
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
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'placed', p.pos_x IS NOT NULL,
                      'creature', p.creature_id IS NOT NULL,
                      'out', CASE WHEN p.creature_id IS NOT NULL AND public.rpg_participant_out(p.id) THEN 'out of the fight' END,
                      'fight', public.rpg_map_in_fight(p.id),
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
    'level', v_l.level, 'name', coalesce(v_pname, v_l.name), 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN p_place IS NOT NULL THEN 'p-' || p_place::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'roads', coalesce(v_roads, '[]'::jsonb), 'road_width', v_rw,
    'crossings', coalesce(v_cross, '[]'::jsonb),
    'houses', coalesce(v_houses, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- the rule cards (step 11): bridges and fords
UPDATE public.rpg_rules
   SET body = replace(body,
                      'Roads cross rivers and lakes on a bridge, a ford or a ferry, but never the sea, and keep out of any place with rough ground of its own, like the Old Forest; through an open place they run on its own ground.',
                      'Roads cross lakes on a causeway and rivers on a bridge or through a ford, but never the sea, and keep out of any place with rough ground of its own, like the Old Forest; through an open place they run on its own ground. Every highway bridges every river it meets; a road fords about one river or stream in three and a lane two in three, one call a stretch, so a lane that fords a river fords it at every crossing; a great river is always bridged and a brook needs only a plank. A ford is knee-deep (0.5 m, +50% a square) from bank to bank and 9 m along the river; a bridge is road over the water. Rivers and streams have planned fords off the roads too, about one in twelve City cells they run through, shown from the City grid down (streams from the District grid): a walk sent through one wades where it would swim.'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('Roads cross rivers and lakes on a bridge, a ford or a ferry' IN body) > 0
   AND position('planned fords off the roads' IN body) = 0;

UPDATE public.rpg_rules
   SET body = replace(body,
                      'rivers and lakes too (a bridge, a ford or a ferry), except over mountains',
                      'rivers and lakes too (a bridge, or a causeway over a lake; where a road fords a river its squares in the water are knee-deep water, +50%), except over mountains'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving'
   AND position('rivers and lakes too (a bridge, a ford or a ferry), except over mountains' IN body) > 0;

