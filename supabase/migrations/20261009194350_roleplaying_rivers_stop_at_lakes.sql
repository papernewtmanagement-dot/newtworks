-- Roleplaying: drawn rivers stop at the shore of a lake (Peter 2026-10-09).
CREATE OR REPLACE FUNCTION public.rpg_map_river_trace(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, seg double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The rivers of a block of a grid as the Maps tab draws them (step 14c, Peter 2026-10-07: rivers wind at every zoom like
-- rivers, not straight runs, and never cross each other). Worked out when asked and never stored. Every river is a
-- downhill one (steps 14f1 to 14f3: great rivers, rivers, streams, brooks): its winding line is rpg_map_river_line, read
-- with map_river_trace_subs (4) points a cell, one piece from each point to the next, for the sizes narrower than the
-- grid's cells (a river as wide as the cells is water there and is not traced).
-- Rows: one short piece of a line, seg = [x1, y1, x2, y2] in cells of this grid from the world's west and north edges;
-- x, y = the cell its middle lies in; k = its size.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the trace: points a cell
     tc AS MATERIALIZED (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_trace_subs')::integer AS m),
     -- the rivers' winding line (rpg_map_river_line) read with that many points a cell, one piece from each point to the
     -- next, for the sizes narrower than the grid's cells
     dl AS MATERIALIZED (
       SELECT r.pid, r.k, r.t, r.x / lad.cell AS x1, r.y / lad.cell AS y1, lead(r.x) OVER w / lad.cell AS x2, lead(r.y) OVER w / lad.cell AS y2,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_width')::double precision AS width
         FROM lad CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_river_line(p_level, tc.m, p_x0 * lad.cell, p_y0 * lad.cell, (p_x0 + p_cols) * lad.cell, (p_y0 + p_rows) * lad.cell, lad.cell) r
       WINDOW w AS (PARTITION BY r.pid ORDER BY r.t)),
     -- (step 14f2, Peter 2026-10-08: a river line ran through the ocean) the sea of the block as this grid draws it
     -- (rpg_map_cells; finer grids draw the coast farther in than the grid the river was found on): a river ends where
     -- it first reaches it, so nothing of that bend downstream of it is drawn, nor any bend the river runs on into from
     -- there (a bend that starts where one that reached the sea ends)
     -- (Peter 2026-10-09: a river ran on into a lake) the water of the block as this grid draws it, sea and lakes (deep
     -- and shallow water: the great lakes, and a river wider than a cell): a piece whose middle lies in lake water is not
     -- drawn, so a river stops at the shore of the lake it runs into and the river out of it starts at its shore
     wa AS MATERIALIZED (SELECT c.x, c.y, c.kind FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows) c WHERE c.kind IN ('sea', 'deep', 'water')),
     sea AS MATERIALIZED (SELECT wa.x, wa.y FROM wa WHERE wa.kind = 'sea'),
     d0 AS MATERIALIZED (
       SELECT dl.pid, dl.t, dl.k, floor((dl.x1 + dl.x2) / 2)::integer AS x, floor((dl.y1 + dl.y2) / 2)::integer AS y, dl.x1, dl.y1, dl.x2, dl.y2
         FROM dl CROSS JOIN lad
        WHERE dl.x2 IS NOT NULL AND dl.width < lad.cell),
     ds AS MATERIALIZED (SELECT d0.pid % 1000000000000 AS id, min(d0.t) AS t FROM d0 JOIN sea ON sea.x = d0.x AND sea.y = d0.y GROUP BY 1),
     bd AS MATERIALIZED (
       SELECT b.id, round(b.ax)::bigint AS ax, round(b.ay)::bigint AS ay, round(b.bx)::bigint AS bx, round(b.by)::bigint AS by, b.joins
         FROM lad CROSS JOIN public.rpg_map_river_bends(p_level, (p_x0 - 2) * lad.cell, (p_y0 - 2) * lad.cell, (p_x0 + p_cols + 2) * lad.cell, (p_y0 + p_rows + 2) * lad.cell, lad.cell, 5) b
        WHERE b.id IN (SELECT d0.pid % 1000000000000 FROM d0)),
     gone AS (
       WITH RECURSIVE g(id, via) AS (
         SELECT bd.id, false FROM bd WHERE bd.id IN (SELECT ds.id FROM ds)
         UNION
         SELECT x.id, true FROM g JOIN bd u ON u.id = g.id AND u.joins = 0 JOIN bd x ON x.ax = u.bx AND x.ay = u.by AND x.id <> u.id)
       SELECT DISTINCT g.id FROM g WHERE g.via),
     dp AS MATERIALIZED (
       SELECT d0.k, d0.x, d0.y, d0.x1, d0.y1, d0.x2, d0.y2
         FROM d0 LEFT JOIN ds ON ds.id = d0.pid % 1000000000000
        WHERE (ds.t IS NULL OR d0.t < ds.t) AND d0.pid % 1000000000000 NOT IN (SELECT gone.id FROM gone))
SELECT dp.x, dp.y, dp.k, ARRAY[dp.x1, dp.y1, dp.x2, dp.y2]
  FROM dp
 WHERE dp.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND dp.y BETWEEN p_y0 AND p_y0 + p_rows - 1
   AND NOT EXISTS (SELECT 1 FROM wa WHERE wa.x = dp.x AND wa.y = dp.y AND wa.kind IN ('deep', 'water'));
$function$;

