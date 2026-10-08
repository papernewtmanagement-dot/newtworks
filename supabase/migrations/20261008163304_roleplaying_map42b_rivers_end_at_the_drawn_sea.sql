-- Roleplaying world map step 14f2 follow-up (Peter 2026-10-08: a river line ran through the ocean on Continent I4 > Country B6). A finer grid
-- draws the coast farther in than the Continent grid that found a great river, so its line could run on over the sea.
-- The Maps tab now draws a river only until it first reaches the sea of the grid shown, and no bend it runs on into.

CREATE OR REPLACE FUNCTION public.rpg_map_river_trace(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, seg double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The rivers of a block of a grid as the Maps tab draws them (step 14c, Peter 2026-10-07: rivers wind at every zoom like
-- rivers, not straight runs, and never cross each other). Worked out when asked and never stored.
-- rpg_map_rivers reads a river's line in each cell from the field at the cell's middle and its slope: the swings a grid
-- can follow from cell to cell (layers at least two cells apart). Drawn that way, a coarse grid showed a river as one
-- point a cell joined up, straight runs. Here a river narrower than the grid's cells is traced closer: on
-- map_river_trace_subs (4) points a cell each way, in the cells within map_river_trace_near (1.5) cells of where
-- rpg_map_rivers puts it, with the same rolls and every swing at least two of those points apart (layers down to half a
-- cell). Its bends now show inside a cell; the next grid down adds only bends smaller than half of this grid's cell, so
-- the line keeps its course as you zoom (within about a quarter of a cell of where the rules read it). The rule that
-- rivers never cross holds here too: each size is read at the level of its side of every bigger river's traced line
-- (rpg_map_river_sides), and only squares of four points on one side of every bigger river carry a line, so a smaller
-- river stops at the bigger one's bank and two lines never cross.
-- Rows: one short piece of a traced line, seg = [x1, y1, x2, y2] in cells of this grid from the world's west and north
-- edges; x, y = the cell its middle lies in; k = its size. Pieces meet end to end (the same side of two squares of
-- points gives the same point). A river as wide as the grid's cells is water there and is not traced.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     tc AS MATERIALIZED (
       -- the trace: points a cell each way, squares from one to the next, how near, the side step
       SELECT q.m, (lad.cell / q.m)::integer AS s,
              (SELECT st.value FROM st WHERE st.key = 'map_river_trace_near')::double precision AS near,
              (SELECT st.value FROM st WHERE st.key = 'map_river_side_step')::double precision AS step
         FROM lad CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_trace_subs')::integer AS m) q),
     cls AS MATERIALIZED (
       -- each size of river this grid shows: its grid's cell, the smallest gap of its wandering layers as rpg_map_rivers
       -- reads it (lo) and as traced (lo2: a river drawn as a line on this grid, where a cell splits into whole squares)
       SELECT q.k, kl.cell::double precision AS kcell, greatest(w.width * w.wave / 4, 2 * lad.cell) AS lo,
              w.width < lad.cell AND tc.m > 1 AND mod(lad.cell::bigint, tc.m) = 0 AS traced,
              greatest(w.width * w.wave / 4, 2 * lad.cell / tc.m) AS lo2
         FROM generate_series(3, 5) AS q(k)
         JOIN public.rpg_map_ladder() kl ON kl.level = q.k
        CROSS JOIN lad CROSS JOIN tc
        CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS wave) w
        WHERE q.k <= p_level),
     -- the share of each scale a river swings: the swing of the smallest bend over its wave (as rpg_map_rivers)
     shr AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_meander_amp')::double precision
                    / (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS share),
     -- where the older rivers run (rpg_map_river_field), on the block and one cell round it (step 14f2: only its streams
     -- and brooks are drawn; its rivers are read for the sides of them)
     r1 AS MATERIALIZED (SELECT r.* FROM public.rpg_map_river_field(p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) r),
     -- the cells near a traced river
     nr AS MATERIALIZED (
       SELECT DISTINCT r1.x, r1.y FROM r1 CROSS JOIN lad CROSS JOIN tc
         JOIN cls c ON c.k = r1.k AND c.traced
        WHERE r1.dist < tc.near * lad.cell AND r1.k > 3),
     dn AS MATERIALIZED (
       -- the trace points those cells need: their own and two rings round them (for the squares on their edges and
       -- the slope at those squares' corners)
       SELECT DISTINCT nr.x * tc.m + a.a AS x, nr.y * tc.m + b.b AS y
         FROM nr CROSS JOIN tc CROSS JOIN generate_series(-2, tc.m + 1) AS a(a) CROSS JOIN generate_series(-2, tc.m + 1) AS b(b)),
     bx AS MATERIALIZED (
       -- the box of trace points that holds them, and which of its points are asked for
       SELECT min(dn.x) AS x0, min(dn.y) AS y0, max(dn.x) - min(dn.x) + 1 AS cols, max(dn.y) - min(dn.y) + 1 AS rows
         FROM dn HAVING count(*) > 0),
     at AS (SELECT array_agg((dn.y - bx.y0) * bx.cols + dn.x - bx.x0) AS at FROM dn CROSS JOIN bx),
     wl2 AS MATERIALIZED (
       -- the wandering layers the trace reads (down to lo2), numbered after the line's own rolls
       SELECT y.n, y.gap::double precision AS gap, (SELECT count(*) FROM cls) + row_number() OVER (ORDER BY y.n)::integer AS i
         FROM public.rpg_map_layers() y
        WHERE EXISTS (SELECT 1 FROM cls c WHERE y.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND y.gap < c.kcell)),
     rd AS (
       -- one reading for each size's line (part 7, its grid's three layers) and one for each wandering layer
       SELECT array_agg(q.part ORDER BY q.i) AS parts, array_agg(q.frst ORDER BY q.i) AS firsts, array_agg(q.fine ORDER BY q.i) AS fines
         FROM (SELECT row_number() OVER (ORDER BY c.k)::integer AS i, 7 AS part, 3 * c.k - 2 AS frst, c.kcell::integer AS fine FROM cls c
               UNION ALL SELECT wl2.i, 9, wl2.n, wl2.gap::integer FROM wl2) q),
     tr AS MATERIALIZED (
       SELECT r.x, r.y, r.vals
         FROM bx CROSS JOIN at CROSS JOIN rd CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_rolls_set(rd.parts, rd.firsts, rd.fines, least(p_level + 1, 7), tc.s, bx.x0, bx.y0, bx.cols, bx.rows, at.at) r
        WHERE EXISTS (SELECT 1 FROM nr)),
     -- each size's place among the line rolls of the readings
     ci AS (SELECT c2.k, row_number() OVER (ORDER BY c2.k)::integer AS i FROM cls c2),
     cw AS MATERIALIZED (
       -- each size's line roll among the readings, and what each wandering layer pushes it per roll (0 when it does not
       -- wander by that layer), by size: 2 great rivers ... 5 brooks
       SELECT (SELECT ci.i FROM ci WHERE ci.k = 2) AS v2, (SELECT ci.i FROM ci WHERE ci.k = 3) AS v3,
              (SELECT ci.i FROM ci WHERE ci.k = 4) AS v4, (SELECT ci.i FROM ci WHERE ci.k = 5) AS v5,
              coalesce(array_agg(wl2.i ORDER BY wl2.i), '{}'::integer[]) AS wi,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 2 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c2,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 3 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c3,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 4 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c4,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 5 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c5
         FROM wl2 CROSS JOIN shr),
     tf AS MATERIALIZED (
       -- each size's line roll and its swing (squares) at each trace point, one row a point
       SELECT tr.x, tr.y, tr.vals[cw.v2] AS b2, tr.vals[cw.v3] AS b3, tr.vals[cw.v4] AS b4, tr.vals[cw.v5] AS b5, sw.s
         FROM tr CROSS JOIN cw
        CROSS JOIN LATERAL (SELECT ARRAY[coalesce(sum(tr.vals[u.i] * u.c2), 0), coalesce(sum(tr.vals[u.i] * u.c3), 0),
                                         coalesce(sum(tr.vals[u.i] * u.c4), 0), coalesce(sum(tr.vals[u.i] * u.c5), 0)] AS s
                              FROM unnest(cw.wi, cw.c2, cw.c3, cw.c4, cw.c5) AS u(i, c2, c3, c4, c5)) sw),
     tsh AS MATERIALIZED (
       -- the pushed field of each size at each trace point with both neighbours each way (slope per square: points tc.s
       -- squares apart), less its level by the sides of the bigger rivers' own traced lines (rpg_map_river_sides)
       SELECT p.x, p.y, p.p2 - l.l2 AS q2, p.p3 - l.l3 AS q3, p.p4 - l.l4 AS q4, p.p5 - l.l5 AS q5, l.s3, l.s4, l.s5
         FROM (SELECT a.x, a.y,
                      1::double precision AS p2,
                      a.b3 + sqrt(power((e.b3 - w.b3) / 2, 2) + power((s.b3 - n.b3) / 2, 2)) / tc.s * a.s[2] AS p3,
                      a.b4 + sqrt(power((e.b4 - w.b4) / 2, 2) + power((s.b4 - n.b4) / 2, 2)) / tc.s * a.s[3] AS p4,
                      a.b5 + sqrt(power((e.b5 - w.b5) / 2, 2) + power((s.b5 - n.b5) / 2, 2)) / tc.s * a.s[4] AS p5
                 FROM tf a CROSS JOIN tc
                 JOIN tf e ON e.x = a.x + 1 AND e.y = a.y
                 JOIN tf w ON w.x = a.x - 1 AND w.y = a.y
                 JOIN tf s ON s.x = a.x AND s.y = a.y + 1
                 JOIN tf n ON n.x = a.x AND n.y = a.y - 1) p
        CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_river_sides(p.p2, p.p3, p.p4, tc.step) l),
     sq AS (
       -- every square of four trace points, for each traced size whose line passes it and whose four corners lie on one
       -- side of every bigger river; its corners a (north-west), b, c, d
       SELECT u.k, a.x, a.y, u.qa, u.qb, u.qc, u.qd
         FROM tsh a
         JOIN tsh b ON b.x = a.x + 1 AND b.y = a.y
         JOIN tsh c ON c.x = a.x + 1 AND c.y = a.y + 1
         JOIN tsh d ON d.x = a.x AND d.y = a.y + 1
        CROSS JOIN LATERAL (VALUES (2, a.q2, b.q2, c.q2, d.q2, true),
                                   (3, a.q3, b.q3, c.q3, d.q3, a.s3 = b.s3 AND a.s3 = c.s3 AND a.s3 = d.s3),
                                   (4, a.q4, b.q4, c.q4, d.q4, a.s4 = b.s4 AND a.s4 = c.s4 AND a.s4 = d.s4),
                                   (5, a.q5, b.q5, c.q5, d.q5, a.s5 = b.s5 AND a.s5 = c.s5 AND a.s5 = d.s5)) AS u(k, qa, qb, qc, qd, one)
         JOIN cls cc ON cc.k = u.k AND cc.traced
        WHERE u.one AND NOT ((u.qa > 0) = (u.qb > 0) AND (u.qa > 0) = (u.qc > 0) AND (u.qa > 0) = (u.qd > 0))),
     ed AS (
       -- where the line crosses each side of the square, in trace points from the world's edges (top, right, bottom,
       -- left); the same side of two squares gives the same point
       SELECT sq.k, sq.x, sq.y, sq.qa, sq.qc,
              CASE WHEN (sq.qa > 0) <> (sq.qb > 0) THEN ARRAY[sq.x + 0.5 + sq.qa / (sq.qa - sq.qb), sq.y + 0.5] END AS et,
              CASE WHEN (sq.qb > 0) <> (sq.qc > 0) THEN ARRAY[sq.x + 1.5, sq.y + 0.5 + sq.qb / (sq.qb - sq.qc)] END AS er,
              CASE WHEN (sq.qd > 0) <> (sq.qc > 0) THEN ARRAY[sq.x + 0.5 + sq.qd / (sq.qd - sq.qc), sq.y + 1.5] END AS eb,
              CASE WHEN (sq.qa > 0) <> (sq.qd > 0) THEN ARRAY[sq.x + 0.5, sq.y + 0.5 + sq.qa / (sq.qa - sq.qd)] END AS el,
              (sq.qa + sq.qb + sq.qc + sq.qd) / 4 AS mid
         FROM sq),
     pc AS MATERIALIZED (
       -- the pieces of line in each square (two where the line passes it twice: split by the middle of the square)
       SELECT ed.k, p.a[1] / tc.m AS x1, p.a[2] / tc.m AS y1, p.b[1] / tc.m AS x2, p.b[2] / tc.m AS y2
         FROM ed CROSS JOIN tc
        CROSS JOIN LATERAL (
          SELECT q.a, q.b FROM (VALUES
            (1, CASE WHEN ed.el IS NULL OR ed.er IS NULL OR ed.et IS NULL OR ed.eb IS NULL THEN coalesce(ed.et, ed.er, ed.eb) END,
                CASE WHEN ed.el IS NULL OR ed.er IS NULL OR ed.et IS NULL OR ed.eb IS NULL THEN coalesce(ed.el, ed.eb, ed.er) END),
            (2, CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN ed.et END,
                CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN CASE WHEN (ed.mid > 0) = (ed.qa > 0) THEN ed.er ELSE ed.el END END),
            (3, CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN ed.eb END,
                CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN CASE WHEN (ed.mid > 0) = (ed.qa > 0) THEN ed.el ELSE ed.er END END)
          ) AS q(o, a, b) WHERE q.a IS NOT NULL AND q.b IS NOT NULL AND q.a <> q.b) p),
     ps AS MATERIALIZED (
       SELECT pc.k, floor((pc.x1 + pc.x2) / 2)::integer AS x, floor((pc.y1 + pc.y2) / 2)::integer AS y, pc.x1, pc.y1, pc.x2, pc.y2 FROM pc),
     -- the downhill rivers (step 14f1): their winding line (rpg_map_river_line) read with p_sub points a cell, one piece
     -- from each point to the next, for the sizes narrower than the grid's cells
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
     sea AS MATERIALIZED (SELECT c.x, c.y FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows) c WHERE c.kind = 'sea'),
     d0 AS MATERIALIZED (
       SELECT dl.pid, dl.t, dl.k, floor((dl.x1 + dl.x2) / 2)::integer AS x, floor((dl.y1 + dl.y2) / 2)::integer AS y, dl.x1, dl.y1, dl.x2, dl.y2,
              greatest(dl.width / 2 / lad.cell, 0.5 / tc.m) AS band
         FROM dl CROSS JOIN lad CROSS JOIN tc
        WHERE dl.x2 IS NOT NULL AND dl.width < lad.cell),
     ds AS MATERIALIZED (SELECT d0.pid % 100000000 AS id, min(d0.t) AS t FROM d0 JOIN sea ON sea.x = d0.x AND sea.y = d0.y GROUP BY 1),
     bd AS MATERIALIZED (
       SELECT b.id, round(b.ax)::bigint AS ax, round(b.ay)::bigint AS ay, round(b.bx)::bigint AS bx, round(b.by)::bigint AS by, b.joins
         FROM lad CROSS JOIN public.rpg_map_river_bends(p_level, (p_x0 - 2) * lad.cell, (p_y0 - 2) * lad.cell, (p_x0 + p_cols + 2) * lad.cell, (p_y0 + p_rows + 2) * lad.cell, true) b
        WHERE b.id IN (SELECT d0.pid % 100000000 FROM d0)),
     gone AS (
       WITH RECURSIVE g(id, via) AS (
         SELECT bd.id, false FROM bd WHERE bd.id IN (SELECT ds.id FROM ds)
         UNION
         SELECT x.id, true FROM g JOIN bd u ON u.id = g.id AND u.joins = 0 JOIN bd x ON x.ax = u.bx AND x.ay = u.by AND x.id <> u.id)
       SELECT DISTINCT g.id FROM g WHERE g.via),
     dp AS MATERIALIZED (
       SELECT d0.k, d0.x, d0.y, d0.x1, d0.y1, d0.x2, d0.y2, d0.band
         FROM d0 LEFT JOIN ds ON ds.id = d0.pid % 100000000
        WHERE (ds.t IS NULL OR d0.t < ds.t) AND d0.pid % 100000000 NOT IN (SELECT gone.id FROM gone))
SELECT ps.x, ps.y, ps.k, ARRAY[ps.x1, ps.y1, ps.x2, ps.y2]
  FROM ps
 WHERE ps.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND ps.y BETWEEN p_y0 AND p_y0 + p_rows - 1
   -- (step 14f2) the older rivers are gone: every river is a downhill one now; streams and brooks are still the older ones
   AND ps.k > 3
   -- an older smaller river stops at the bank of a downhill one (it does not cross it)
   AND NOT EXISTS (SELECT 1 FROM dp
                    WHERE dp.k <= ps.k
                      AND least(ps.x1, ps.x2) <= greatest(dp.x1, dp.x2) + dp.band AND greatest(ps.x1, ps.x2) >= least(dp.x1, dp.x2) - dp.band
                      AND least(ps.y1, ps.y2) <= greatest(dp.y1, dp.y2) + dp.band AND greatest(ps.y1, ps.y2) >= least(dp.y1, dp.y2) - dp.band
                      AND public.rpg_seg_gap(ps.x1, ps.y1, ps.x2, ps.y2, dp.x1, dp.y1, dp.x2, dp.y2) < dp.band)
UNION ALL
SELECT dp.x, dp.y, dp.k, ARRAY[dp.x1, dp.y1, dp.x2, dp.y2]
  FROM dp
 WHERE dp.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND dp.y BETWEEN p_y0 AND p_y0 + p_rows - 1;
$function$;

