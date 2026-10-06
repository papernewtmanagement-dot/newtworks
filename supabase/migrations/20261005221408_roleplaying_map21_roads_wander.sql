-- Roleplaying world map, step 10b: roads wander (Peter 2026-10-05). The line of a stretch of road bends about the straight
-- line between its ends, the same way at every zoom; the road squares of the battle grid, the walk along the road and the
-- houses along the street follow it. New: rpg_map_road_lines, rpg_map_road_line, rpg_map_road_swing, rpg_map_road_reaches,
-- rpg_map_road_snap and six settings. Changed: rpg_map_roads, rpg_map_road_cells, rpg_map_view_block, rpg_map_buildings,
-- rpg_map_road_path, rpg_map_walk; the rule card The World Map. No drops, no table changes.

-- step 10b: the wandering line of a stretch of road (the one home of where a road runs between its two ends)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_road_1_wander', 0.06::numeric, 'Highways: how far the biggest bend swings sideways, as a share of its length (a highway runs nearly straight: the Roman roads)'),
               ('map_road_2_wander', 0.09, 'Roads: how far the biggest bend swings sideways, as a share of its length'),
               ('map_road_3_wander', 0.12, 'Lanes: how far the biggest bend swings sideways, as a share of its length'),
               ('map_road_wander_bend', 5184, 'Roads: the longest bend a road makes, in squares (3.6 miles); a longer stretch is cut into as many bends as it holds'),
               ('map_road_wander_decay', 0.7, 'Roads: each bend half as long as the last swings this share as far for its length, so a road is smoothest close up'),
               ('map_road_wander_wave', 25, 'Roads: the shortest bend a road makes, in road widths (a lane 2.4 m wide bends over 60 m at the least)')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_road_swing()
 RETURNS double precision
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The most a stretch of road can wander sideways from the straight line between its ends, in squares (step 10b): every
-- bend of rpg_map_road_lines at its farthest the same way. The margin rpg_map_roads adds round a block when it looks
-- for the stretches whose line may reach it. 1,641 squares (1.1 miles) as the settings stand.
SELECT (49.5 / sqrt(9999 / 12.0)) * max(s.value) FILTER (WHERE s.key IN ('map_road_1_wander', 'map_road_2_wander', 'map_road_3_wander'))
       * max(s.value) FILTER (WHERE s.key = 'map_road_wander_bend')
       / (1 - max(s.value) FILTER (WHERE s.key = 'map_road_wander_decay') / 2)
  FROM public.rpg_settings s
 WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND s.key IN ('map_road_1_wander', 'map_road_2_wander', 'map_road_3_wander', 'map_road_wander_bend', 'map_road_wander_decay');
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_lines(p_class integer[], p_ax double precision[], p_ay double precision[], p_bx double precision[], p_by double precision[],
                                                    p_a text[], p_b text[], p_cell double precision, p_s double precision[] DEFAULT NULL,
                                                    p_x0 double precision DEFAULT NULL, p_y0 double precision DEFAULT NULL, p_x1 double precision DEFAULT NULL, p_y1 double precision DEFAULT NULL,
                                                    p_per integer DEFAULT 6)
 RETURNS TABLE(i integer, n integer, s double precision, x double precision, y double precision, ux double precision, uy double precision, rest double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the roads run (step 10b): the one home of the line between the two ends of a stretch that rpg_map_roads gives
-- (class 1 highway, 2 road, 3 lane; its ends a and b in world squares and their ids), for several stretches at once
-- (i = which, from 1). The road wanders about the straight line between its ends, the same way at every zoom, and comes
-- back to the line at each end.
-- Bends: the stretch is cut into equal bends, as few as fit map_road_wander_bend (5,184 squares, 3.6 miles) and at least
-- two; each bend swings the road sideways by a fixed-seed roll at its ends (part 13, layer 1300 + k for the k-th size
-- of bend: rpg_map_roll at the knot along the stretch, keyed to the two ends), eased from one roll to the next
-- (3u^2 - 2u^3, as the rolls of the ground are). The swing at the biggest bends is map_road_<class>_wander of their
-- length (a highway 6 in 100, a road 9, a lane 12); then bends half as long, half as long again, down to
-- map_road_wander_wave road widths, each swinging map_road_wander_decay (0.7) as far for its length as the one before,
-- so a road is smoothest close up. The ends of every bend size roll 0 at the two ends of the stretch, so the road
-- leaves each end straight along the line.
-- Reads the bends at least twice p_cell long (a grid draws the bends it can show: a point every half cell at least, and
-- p_per to a bend of the finest size read, 6 unless asked; p_cell NULL reads the two biggest sizes only, a quick look
-- at where the road may reach), at points every so far along the line (n = 0 at a, the last at b; s = how far along
-- the straight line, x, y where the road is, ux, uy the way it runs there). p_s asks instead for the points at those
-- distances along the line (n = 1 for the first); past either end the road runs on straight. rest = how much farther
-- the road may stray from these points: the bends finer than those read (of those a road makes), at their farthest,
-- and the curve between one point and the next.
-- A box (p_x0, p_y0 to p_x1, p_y1, in squares) asks only for the points near it: a quick look at the two biggest
-- sizes of bend says which parts of the stretch can reach the box, and only those parts are read in full (n keeps its
-- count along the whole stretch, so a jump in n is a part left out).
BEGIN
  RETURN QUERY
  WITH st AS (SELECT s.key, s.value::double precision AS v FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
               AND (s.key IN ('map_seed', 'map_road_wander_bend', 'map_road_wander_decay', 'map_road_wander_wave')
                    OR s.key LIKE 'map\_road\__\_wander' OR s.key LIKE 'map\_road\__\_width')),
     cfg AS (SELECT max(st.v) FILTER (WHERE st.key = 'map_seed')::integer AS seed, max(st.v) FILTER (WHERE st.key = 'map_road_wander_bend') AS bend,
                    max(st.v) FILTER (WHERE st.key = 'map_road_wander_decay') / 2 AS r, max(st.v) FILTER (WHERE st.key = 'map_road_wander_wave') AS wave
               FROM st),
     cw AS (SELECT substr(st.key, 10, 1)::integer AS class, max(st.v) FILTER (WHERE st.key LIKE '%wander') AS share, max(st.v) FILTER (WHERE st.key LIKE '%width') AS width
              FROM st WHERE st.key LIKE 'map\_road\__\_%' GROUP BY 1),
     -- each stretch: its length, which way it is counted (the rolls run from the end whose id sorts first), its key,
     -- the way along it, its bends (n0 of the biggest, each gap0 long), how far its bends swing at most and the finest
     ln AS (SELECT q.i::integer AS i, q.class, q.ax, q.ay, q.bx, q.by, l.len, q.a > q.b AS flip,
                   ('x' || substr(md5(least(q.a, q.b) || '>' || greatest(q.a, q.b)), 1, 8))::bit(32)::integer AS key,
                   CASE WHEN l.len > 0 THEN (q.bx - q.ax) / l.len ELSE 1 END AS ux, CASE WHEN l.len > 0 THEN (q.by - q.ay) / l.len ELSE 0 END AS uy,
                   n0.n0, l.len / n0.n0 AS gap0, cw.share, greatest(coalesce(2 * p_cell, 0), cfg.wave * cw.width) AS fine,
                   CASE WHEN l.len > 0 AND l.len / n0.n0 >= cfg.wave * cw.width THEN floor(ln(l.len / n0.n0 / (cfg.wave * cw.width)) / ln(2.0))::integer + 1 ELSE 0 END AS kall
              FROM unnest(p_class, p_ax, p_ay, p_bx, p_by, p_a, p_b) WITH ORDINALITY AS q(class, ax, ay, bx, by, a, b, i)
              JOIN cw ON cw.class = q.class CROSS JOIN cfg
             CROSS JOIN LATERAL (SELECT sqrt(power(q.bx - q.ax, 2) + power(q.by - q.ay, 2)) AS len) l
             CROSS JOIN LATERAL (SELECT greatest(2, ceil(l.len / cfg.bend))::integer AS n0) n0),
     -- the sizes of bend read: k = 0 the biggest, m bends of gap squares each, swinging amp
     oc AS (SELECT ln.i, k, ln.gap0 / power(2, k) AS gap, (ln.n0 * power(2, k))::integer AS m, ln.share * ln.gap0 * power(cfg.r, k) AS amp
              FROM ln CROSS JOIN cfg CROSS JOIN generate_series(0, 24) AS k
             WHERE ln.len > 0 AND CASE WHEN p_cell IS NULL THEN k <= 1 AND ln.gap0 / power(2, k) >= ln.fine ELSE ln.gap0 / power(2, k) >= ln.fine END),
     -- the rolls at the knots of each size, 0 at the two ends
     kn AS (SELECT oc.i, oc.k, oc.gap, oc.amp, oc.m,
                   array_agg(CASE WHEN j = 0 OR j = oc.m THEN 0
                                  ELSE (public.rpg_map_roll(cfg.seed, 1300 + oc.k, j, ln.key) - 50.5) / sqrt(9999 / 12.0) END ORDER BY j) AS v
              FROM oc JOIN ln ON ln.i = oc.i CROSS JOIN cfg CROSS JOIN generate_series(0, oc.m) AS j
             GROUP BY oc.i, oc.k, oc.gap, oc.amp, oc.m),
     -- what is read of each stretch: the finest bend, the points every h along the line (a sixth of the finest bend and
     -- at least half a cell), and how far the road may stray from the points
     rd AS MATERIALIZED (
            SELECT ln.*, coalesce(greatest(o.gap / greatest(coalesce(p_per, 6), 1), p_cell / 2), o.gap / greatest(coalesce(p_per, 6), 1), ln.len) AS h,
                   (49.5 / sqrt(9999 / 12.0)) * ln.share * ln.gap0 * greatest(power(cfg.r, coalesce(o.kmax + 1, 0)) - power(cfg.r, ln.kall), 0) / (1 - cfg.r)
                   + 0.16 * coalesce(o.amp, 0) * power(6.0 / greatest(coalesce(p_per, 6), 1), 2) AS rest
              FROM ln CROSS JOIN cfg
              LEFT JOIN (SELECT oc.i, min(oc.gap) AS gap, max(oc.k) AS kmax, min(oc.amp) AS amp FROM oc GROUP BY oc.i) o ON o.i = ln.i),
     -- a quick look when a box is given: the two biggest sizes of bend, six points to a bend, and how far the rest of
     -- the bends can take the road from them; the parts of the stretch (from one of those points to the next) that can
     -- reach the box
     cq AS (SELECT ln.i, g.n, g.n * ln.len / q.m AS s
              FROM ln JOIN (SELECT oc.i, min(oc.gap) AS gap FROM oc WHERE oc.k <= 1 GROUP BY oc.i) o ON o.i = ln.i
             CROSS JOIN LATERAL (SELECT greatest(1, ceil(ln.len / nullif(o.gap / 6, 0)))::integer AS m) q
             CROSS JOIN LATERAL generate_series(0, q.m) AS g(n)
             WHERE p_x0 IS NOT NULL AND p_s IS NULL),
     cv AS (SELECT cq.i, cq.n, cq.s,
                   coalesce(sum(kn.amp * (kn.v[q.j + 1] + (kn.v[q.j + 2] - kn.v[q.j + 1]) * q.w * q.w * (3 - 2 * q.w))), 0) AS f
              FROM cq JOIN ln ON ln.i = cq.i
              LEFT JOIN kn ON kn.i = cq.i AND kn.k <= 1
             CROSS JOIN LATERAL (SELECT least(greatest(CASE WHEN ln.flip THEN ln.len - cq.s ELSE cq.s END, 0), ln.len) AS sc) c
             CROSS JOIN LATERAL (SELECT least(floor(c.sc / kn.gap), kn.m - 1)::integer AS j) jj
             CROSS JOIN LATERAL (SELECT jj.j, c.sc / kn.gap - jj.j AS w) q
             GROUP BY cq.i, cq.n, cq.s),
     cp AS (SELECT cv.i, cv.n, cv.s, ln.ax + ln.ux * cv.s - ln.uy * g.g AS x, ln.ay + ln.uy * cv.s + ln.ux * g.g AS y
              FROM cv JOIN ln ON ln.i = cv.i CROSS JOIN LATERAL (SELECT CASE WHEN ln.flip THEN -cv.f ELSE cv.f END AS g) g),
     cs AS MATERIALIZED (SELECT a.i, a.s AS s0, b.s AS s1
              FROM cp a JOIN cp b ON b.i = a.i AND b.n = a.n + 1 JOIN ln ON ln.i = a.i CROSS JOIN cfg
             CROSS JOIN LATERAL (SELECT (49.5 / sqrt(9999 / 12.0)) * ln.share * ln.gap0 * greatest(power(cfg.r, 2) - power(cfg.r, ln.kall), 0) / (1 - cfg.r)
                                        + 0.16 * ln.share * ln.gap0 * cfg.r AS far) f
             WHERE least(a.x, b.x) <= p_x1 + f.far AND greatest(a.x, b.x) >= p_x0 - f.far AND least(a.y, b.y) <= p_y1 + f.far AND greatest(a.y, b.y) >= p_y0 - f.far),
     pt AS (SELECT ln.i, u.n::integer AS n, u.s FROM ln CROSS JOIN unnest(p_s) WITH ORDINALITY AS u(s, n) WHERE p_s IS NOT NULL
            UNION ALL
            SELECT rd.i, g.n, g.n * rd.len / q.m
              FROM rd
             CROSS JOIN LATERAL (SELECT greatest(1, ceil(rd.len / nullif(rd.h, 0)))::integer AS m) q
             CROSS JOIN LATERAL generate_series(0, q.m) AS g(n)
             WHERE p_s IS NULL
               AND (p_x0 IS NULL OR EXISTS (SELECT 1 FROM cs WHERE cs.i = rd.i AND g.n * rd.len / q.m BETWEEN cs.s0 - rd.h AND cs.s1 + rd.h))),
     ev AS (SELECT pt.i, pt.n, pt.s,
                   coalesce(sum(kn.amp * (kn.v[q.j + 1] + (kn.v[q.j + 2] - kn.v[q.j + 1]) * q.w * q.w * (3 - 2 * q.w))), 0) AS f,
                   coalesce(sum(kn.amp * (kn.v[q.j + 2] - kn.v[q.j + 1]) * 6 * q.w * (1 - q.w) / kn.gap), 0) AS df
              FROM pt JOIN ln ON ln.i = pt.i
              LEFT JOIN kn ON kn.i = pt.i
             CROSS JOIN LATERAL (SELECT least(greatest(CASE WHEN ln.flip THEN ln.len - pt.s ELSE pt.s END, 0), ln.len) AS sc) c
             CROSS JOIN LATERAL (SELECT least(floor(c.sc / kn.gap), kn.m - 1)::integer AS j) jj
             CROSS JOIN LATERAL (SELECT jj.j, c.sc / kn.gap - jj.j AS w) q
             GROUP BY pt.i, pt.n, pt.s)
SELECT ev.i, ev.n, ev.s, rd.ax + rd.ux * ev.s - rd.uy * g.g, rd.ay + rd.uy * ev.s + rd.ux * g.g, (rd.ux - rd.uy * ev.df) / g.nm, (rd.uy + rd.ux * ev.df) / g.nm, rd.rest
  FROM ev JOIN rd ON rd.i = ev.i
 CROSS JOIN LATERAL (SELECT CASE WHEN rd.flip THEN -ev.f ELSE ev.f END AS g, sqrt(1 + ev.df * ev.df) AS nm) g
 ORDER BY ev.i, ev.n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_line(p_class integer, p_ax double precision, p_ay double precision, p_bx double precision, p_by double precision,
                                                   p_a text, p_b text, p_cell double precision, p_s double precision[] DEFAULT NULL,
                                                   p_x0 double precision DEFAULT NULL, p_y0 double precision DEFAULT NULL, p_x1 double precision DEFAULT NULL, p_y1 double precision DEFAULT NULL,
                                                   p_per integer DEFAULT 6)
 RETURNS TABLE(n integer, s double precision, x double precision, y double precision, ux double precision, uy double precision, rest double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The wandering line of one stretch of road (step 10b): rpg_map_road_lines for a single stretch.
SELECT l.n, l.s, l.x, l.y, l.ux, l.uy, l.rest
  FROM public.rpg_map_road_lines(ARRAY[p_class], ARRAY[p_ax], ARRAY[p_ay], ARRAY[p_bx], ARRAY[p_by], ARRAY[p_a], ARRAY[p_b], p_cell, p_s, p_x0, p_y0, p_x1, p_y1, p_per) l;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_reaches(p_class integer[], p_ax double precision[], p_ay double precision[], p_bx double precision[], p_by double precision[],
                                                      p_a text[], p_b text[], p_x0 double precision, p_y0 double precision, p_x1 double precision, p_y1 double precision)
 RETURNS integer[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Which of these stretches of road may reach the box p_x0, p_y0 to p_x1, p_y1 (squares), by their place in the arrays
-- (from 1), in order (step 10b): a stretch whose straight line crosses the box, or whose wandering line
-- (rpg_map_road_lines: a quick look at its two biggest sizes of bend, grown by all the road may still stray, then a
-- closer look at the few that may) comes near it (the box round each piece of that line, so a stretch may be kept that
-- misses the box by a corner). rpg_map_roads asks this before it reads who lives at the ends of a stretch, so a block only pays for the
-- stretches that can reach it. Nothing when none can.
WITH q AS (SELECT u.i::integer AS i, u.class, u.ax, u.ay, u.bx, u.by, u.a, u.b, public.rpg_seg_box(u.ax, u.ay, u.bx, u.by, p_x0, p_y0, p_x1, p_y1) AS straight
             FROM unnest(p_class, p_ax, p_ay, p_bx, p_by, p_a, p_b) WITH ORDINALITY AS u(class, ax, ay, bx, by, a, b, i)),
     o AS (SELECT array_agg(q.i ORDER BY q.i) AS i, array_agg(q.class ORDER BY q.i) AS class, array_agg(q.ax ORDER BY q.i) AS ax, array_agg(q.ay ORDER BY q.i) AS ay,
                  array_agg(q.bx ORDER BY q.i) AS bx, array_agg(q.by ORDER BY q.i) AS by, array_agg(q.a ORDER BY q.i) AS a, array_agg(q.b ORDER BY q.i) AS b
             FROM q WHERE NOT q.straight HAVING count(*) > 0),
     lp AS MATERIALIZED (SELECT o.i[l.i] AS i, l.n, l.x, l.y, l.rest FROM o CROSS JOIN LATERAL public.rpg_map_road_lines(o.class, o.ax, o.ay, o.bx, o.by, o.a, o.b, NULL) l),
     nr AS (SELECT DISTINCT a.i
              FROM lp a JOIN lp b ON b.i = a.i AND b.n = a.n + 1
             WHERE least(a.x, b.x) <= p_x1 + a.rest AND greatest(a.x, b.x) >= p_x0 - a.rest AND least(a.y, b.y) <= p_y1 + a.rest AND greatest(a.y, b.y) >= p_y0 - a.rest),
     -- the few that may: a closer look (the bends a City grid shows) before their ends are read
     o2 AS (SELECT array_agg(q.i ORDER BY q.i) AS i, array_agg(q.class ORDER BY q.i) AS class, array_agg(q.ax ORDER BY q.i) AS ax, array_agg(q.ay ORDER BY q.i) AS ay,
                   array_agg(q.bx ORDER BY q.i) AS bx, array_agg(q.by ORDER BY q.i) AS by, array_agg(q.a ORDER BY q.i) AS a, array_agg(q.b ORDER BY q.i) AS b
              FROM q WHERE q.i IN (SELECT nr.i FROM nr) HAVING count(*) > 0),
     lf AS MATERIALIZED (SELECT o2.i[l.i] AS i, l.n, l.x, l.y, l.rest
                           FROM o2 CROSS JOIN LATERAL public.rpg_map_road_lines(o2.class, o2.ax, o2.ay, o2.bx, o2.by, o2.a, o2.b,
                                                                                (SELECT w.cell::double precision FROM public.rpg_map_ladder() w WHERE w.level = 5)) l),
     nf AS (SELECT DISTINCT a.i
              FROM lf a JOIN lf b ON b.i = a.i AND b.n = a.n + 1
             WHERE least(a.x, b.x) <= p_x1 + a.rest AND greatest(a.x, b.x) >= p_x0 - a.rest AND least(a.y, b.y) <= p_y1 + a.rest AND greatest(a.y, b.y) >= p_y0 - a.rest)
SELECT array_agg(k.i ORDER BY k.i)
  FROM (SELECT q.i FROM q WHERE q.straight UNION SELECT nf.i FROM nf) k;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_snap(p_x integer, p_y integer, p_reach integer DEFAULT 120)
 RETURNS TABLE(x integer, y integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The square of a road nearest the square p_x, p_y (world squares from 0), within p_reach squares of it (step 10b):
-- the stretches whose line may come that near (rpg_map_roads), their lines read in full there (rpg_map_road_lines),
-- and the nearest point of the nearest piece of them, rounded to its square. Nothing when no road comes that near.
-- A walk plans its way along a chain of points of the road 216 squares or so apart (rpg_map_road_path), so it puts
-- its last square on the road itself with this (rpg_map_walk); the stretches that plan looked at, kept in the setting
-- rpg.roadplan of the transaction, are the ones looked at here when they are there, else rpg_map_roads is asked.
WITH pl AS (SELECT coalesce(nullif(current_setting('rpg.roadplan', true), ''), 'null')::jsonb AS plan),
     lg AS MATERIALIZED (
       SELECT row_number() OVER () AS n, q.class, q.ax, q.ay, q.bx, q.by, q.a, q.b
         FROM (SELECT (e.v ->> 0)::integer AS class, (e.v ->> 1)::double precision AS ax, (e.v ->> 2)::double precision AS ay,
                      (e.v ->> 3)::double precision AS bx, (e.v ->> 4)::double precision AS by, e.v ->> 5 AS a, e.v ->> 6 AS b
                 FROM pl CROSS JOIN LATERAL jsonb_array_elements(pl.plan) AS e(v)
                WHERE jsonb_typeof(pl.plan) = 'array'
               UNION ALL
               SELECT r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b
                 FROM pl CROSS JOIN LATERAL public.rpg_map_roads(7, p_x - p_reach, p_y - p_reach, 2 * p_reach + 1, 2 * p_reach + 1, 7, NULL, 0) r
                WHERE jsonb_typeof(pl.plan) IS DISTINCT FROM 'array') q),
     la AS (SELECT array_agg(lg.class ORDER BY lg.n) AS class, array_agg(lg.ax ORDER BY lg.n) AS ax, array_agg(lg.ay ORDER BY lg.n) AS ay,
                   array_agg(lg.bx ORDER BY lg.n) AS bx, array_agg(lg.by ORDER BY lg.n) AS by, array_agg(lg.a ORDER BY lg.n) AS a, array_agg(lg.b ORDER BY lg.n) AS b
              FROM lg HAVING count(*) > 0),
     lp AS MATERIALIZED (
       SELECT p.i, p.n, p.x, p.y
         FROM la CROSS JOIN LATERAL public.rpg_map_road_lines(la.class, la.ax, la.ay, la.bx, la.by, la.a, la.b, 1, NULL,
                                                              p_x - p_reach, p_y - p_reach, p_x + p_reach + 1, p_y + p_reach + 1) p),
     sg AS (SELECT a.x AS ax, a.y AS ay, b.x AS bx, b.y AS by FROM lp a JOIN lp b ON b.i = a.i AND b.n = a.n + 1)
SELECT round(sg.ax + t.t * (sg.bx - sg.ax))::integer, round(sg.ay + t.t * (sg.by - sg.ay))::integer
  FROM sg
 CROSS JOIN LATERAL (SELECT CASE WHEN power(sg.bx - sg.ax, 2) + power(sg.by - sg.ay, 2) = 0 THEN 0
                                 ELSE least(greatest(((p_x - sg.ax) * (sg.bx - sg.ax) + (p_y - sg.ay) * (sg.by - sg.ay))
                                                     / (power(sg.bx - sg.ax, 2) + power(sg.by - sg.ay, 2)), 0), 1) END AS t) t
 CROSS JOIN LATERAL (SELECT greatest(abs(sg.ax + t.t * (sg.bx - sg.ax) - p_x), abs(sg.ay + t.t * (sg.by - sg.ay) - p_y)) AS gap) d
 WHERE d.gap <= p_reach
 ORDER BY d.gap, sg.ax, sg.ay
 LIMIT 1;
$function$;

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
BEGIN
  IF p_level < 3 OR coalesce(p_what, 0) = 0 THEN RETURN; END IF;
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

  RETURN QUERY
  SELECT DISTINCT ON (least(o.a, o.b), greatest(o.a, o.b)) o.cls, o.ax, o.ay, o.bx, o.by, o.a, o.b
    FROM unnest(o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b) AS o(cls, ax, ay, bx, by, a, b)
   WHERE NOT EXISTS (SELECT 1 FROM unnest(r_x, r_y, r_w, r_h) AS r(x, y, w, h)
                      WHERE public.rpg_map_seg_oval(o.ax, o.ay, o.bx, o.by, r.x, r.y, r.w, r.h, c.world::double precision))
   ORDER BY least(o.a, o.b), greatest(o.a, o.b), o.cls;
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
-- this small (a highway is 6.5 m wide, a square 1.1 m); rpg_map_cells makes them road ground.
-- class = the biggest road there (1 highway, 2 road, 3 lane).
WITH lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     w AS (SELECT substr(s.key, 10, 1)::integer AS class, s.value::double precision / 2 AS half FROM public.rpg_settings s
            WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width')),
     lg AS MATERIALIZED (
       SELECT row_number() OVER () AS n, r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b, w.half
         FROM public.rpg_map_roads(p_level, p_x0, p_y0, p_cols, p_rows, 7, NULL, 0) r JOIN w ON w.class = r.class),
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
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level, v_x0, v_y0, v_cols, v_rows) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
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
         (SELECT array_agg(DISTINCT cl.house) FROM cl WHERE cl.seen AND cl.house IS NOT NULL)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen;

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
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
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
           (SELECT jsonb_object_agg(d.x || ',' || d.y, 1) FROM d WHERE d.seen AND d.kind <> 'sea')
      INTO v_detail, v_dtowns, v_dkinds, v_dshown
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
                      CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END AS sub),
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
           SELECT p.i AS n, la.class[p.i] AS class, p.n AS i, p.x / g.cell - g.x0 AS u, p.y / g.cell - g.y0 AS v,
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
                 WHERE q.qu IS NOT NULL AND NOT q.qok)
    SELECT jsonb_agg(q.piece ORDER BY q.class DESC, q.n, q.run)
      INTO v_roads
      FROM (SELECT pc.n, pc.class, pc.run, jsonb_build_array(pc.class) || jsonb_agg(e.val ORDER BY pc.o, e.i) AS piece
              FROM pc CROSS JOIN g
             CROSS JOIN LATERAL (VALUES (1, round(pc.u * 1000 / g.sub)::integer), (2, round(pc.v * 1000 / g.sub)::integer)) AS e(i, val)
             GROUP BY pc.n, pc.class, pc.run
            HAVING count(*) >= 4) q;
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
    'houses', coalesce(v_houses, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_buildings(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision, half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The houses that stand on a block of the battle grid (step 8c, Peter 2026-10-03 23:12: buildings are climbed like
-- any steep surface), worked out when asked and never stored, the way the villages, towns and cities (rpg_map_towns)
-- and the roads (rpg_map_roads) are: the one home of where buildings stand. They are laid off the roads and the
-- middles of the settlements, so a change to either moves them too. Only the battle grid has them; a coarser grid shows the
-- settlement's ground.
-- Every village, town and city (rpg_map_towns), and every village, town or city place card (Haven), lines each road,
-- lane or highway that runs through it with plots on both sides, the way medieval surveyors laid out a street. A
-- settlement has one plot width: both sides of all its streets shared out among its households (its people over
-- map_house_people, 4.5 a house), held inside its kind's range, map_house_plot_<kind>_low to _high perches
-- (map_house_perch_m, 5.03 m): a village toft 2 to 4 perches, a town burgage 1.5 to 2.5, a city plot 1 to 1.5
-- (Roberts 1987 on regular toft rows; Conzen 1960 and Slater 1981 on burgage widths in perches). A village of 120 on a
-- 270 m street gets 4-perch tofts and about 25 houses; a town of 3,500 on 3 km of streets 1.5-perch burgages. A card
-- (Haven) has as many people as its ground holds at its kind's crowding (map_<kind>_density). The plots are counted out
-- from where the road passes nearest the middle, so every block counts them alike. A settlement whose middle only one
-- road reaches lets that road run on through the middle as its street, to the far side, so a village at the end of its
-- lane still has a street through it. A road wanders (step 10b, rpg_map_road_lines): the plots are counted along the
-- straight line between the ends of its stretch, and each stands where the road truly runs at that count, square to
-- the road there; past either end the street runs on straight.
-- Each plot rolls its own house (part 12, layers 1211 to 1219 for the left side, 1221 to 1229 for the right, at the
-- square in the middle of the plot on the road's line):
--   village: a cottage or longhouse 4 to 5.5 m wide (map_house_span_low, _high) and 2 to 4 bays long, a bay 4.6 m
--     (map_house_bay_m; the 15-foot bay of timber framing), one storey under thatch pitched 45 to 55 degrees
--     (map_house_thatch_low, _high), set back 0 to 4 m from the lane (map_house_setback_high); it stands long side to
--     the lane when its plot leaves map_house_gap_m (2 m) to spare, else gable end to the lane, and anywhere along its
--     plot (Dyer 1986 and Gardiner 2014 on peasant houses);
--   town: fills its plot's width less a passage (map_house_passage_m, 1 m) on half the plots, 2 to 3 bays deep,
--     two storeys, on the street line, under clay tiles pitched 40 to 50 degrees (map_house_tile_low, _high);
--   city: the same with two or three storeys.
-- Storeys and their height come from map_house_storeys_<kind>_low, _high and map_house_storey_low, _high (2.4 to 2.9 m
-- a storey, to the eaves). The ridge runs along the longer side.
-- A house stands only when the whole of it lies on its settlement's own ground (its corners and the middles of its
-- sides: rpg_map_town_edge, or the card's own edge, rpg_map_within), clear of every road and street (half its width
-- from its line), clear of the houses of a bigger road, of the road counted first and of the plots nearer the middle,
-- on dry land (no sea under it, rpg_map_heights) and with no river or lake under it, corners, sides or middle (rpg_map_flow).
-- Returns the houses that reach into the block: id (h<road>-<x>-<y><side>), the settlement, its kind, roof (thatch or
-- tile), its middle (cx, cy, world squares counted the way the block counts), the way its ridge runs (ux, uy), half its
-- length and width in squares, the height to its eaves in metres, its roof's pitch in degrees and its storeys.
-- One read of the map asks for the same ground more than once (a block's costs, then its picture; a fight board, then
-- the climb onto one square), so what is worked out is kept in settings of the transaction and gone when it ends: each
-- settlement's streets and plot width (rpg.townstreets, by settlement), whether each house stands on its own dry
-- ground (rpg.houseok, by house) and each block's houses (rpg.houses, by block "x,y,cols,rows").
#variable_conflict use_column
DECLARE
  v_key text := p_x0 || ',' || p_y0 || ',' || p_cols || ',' || p_rows;
  v_all jsonb;
  v_c jsonb;
  g record;
  t record;
  v_tw jsonb;
  v_tl jsonb;
  v_hb jsonb;
  v_ok jsonb;
  v_new jsonb;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.houses', true), ''), '{}')::jsonb;
  v_c := v_all -> v_key;
  IF v_c IS NULL THEN
    -- the numbers, read once; r = how far a house reaches from its middle at most, in squares (half the diagonal of
    -- the biggest house, and one more)
    WITH st AS (SELECT s.key, s.value::double precision AS v FROM public.rpg_settings s
                 WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                   AND (s.key LIKE 'map\_house\_%' OR s.key IN ('map_square_m', 'map_seed', 'map_edge_share', 'map_sea_level',
                                                                'map_road_1_width', 'map_road_2_width', 'map_road_3_width'))),
         cfg AS (
           SELECT max(st.v) FILTER (WHERE st.key = 'map_square_m') AS sq, max(st.v) FILTER (WHERE st.key = 'map_seed')::integer AS seed,
                  max(st.v) FILTER (WHERE st.key = 'map_edge_share') AS share, max(st.v) FILTER (WHERE st.key = 'map_sea_level') AS sea,
                  max(st.v) FILTER (WHERE st.key = 'map_house_perch_m') AS perch, max(st.v) FILTER (WHERE st.key = 'map_house_bay_m') AS bay,
                  max(st.v) FILTER (WHERE st.key = 'map_house_span_low') AS span_lo, max(st.v) FILTER (WHERE st.key = 'map_house_span_high') AS span_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_storey_low') AS storey_lo, max(st.v) FILTER (WHERE st.key = 'map_house_storey_high') AS storey_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_thatch_low') AS thatch_lo, max(st.v) FILTER (WHERE st.key = 'map_house_thatch_high') AS thatch_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_tile_low') AS tile_lo, max(st.v) FILTER (WHERE st.key = 'map_house_tile_high') AS tile_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_setback_high') AS setback_hi, max(st.v) FILTER (WHERE st.key = 'map_house_passage_m') AS passage,
                  max(st.v) FILTER (WHERE st.key = 'map_house_gap_m') AS gap, max(st.v) FILTER (WHERE st.key = 'map_house_people') AS household,
                  max(st.v) FILTER (WHERE st.key = 'map_house_bays_village_low') AS vbays_lo, max(st.v) FILTER (WHERE st.key = 'map_house_bays_village_high') AS vbays_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_bays_town_low') AS tbays_lo, max(st.v) FILTER (WHERE st.key = 'map_house_bays_town_high') AS tbays_hi,
                  max(st.v) FILTER (WHERE st.key IN ('map_house_plot_town_high', 'map_house_plot_city_high')) AS plot_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_road_1_width') AS w1, max(st.v) FILTER (WHERE st.key = 'map_road_2_width') AS w2,
                  max(st.v) FILTER (WHERE st.key = 'map_road_3_width') AS w3,
                  (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1)::double precision AS world
             FROM st)
    SELECT cfg.*, ceil(greatest(sqrt(power(cfg.vbays_hi * cfg.bay, 2) + power(cfg.span_hi, 2)),
                                sqrt(power(cfg.tbays_hi * cfg.bay, 2) + power(cfg.plot_hi * cfg.perch, 2))) / 2 / cfg.sq) + 1 AS r
      INTO g FROM cfg;

    -- the villages, towns and cities whose ground reaches the box of the houses that might overlap those reaching the
    -- block (three reaches round it): the rolled ones, and the place cards of a village, town or city (their oval grown
    -- by how far their edge may wander; the copy nearest the block)
    SELECT coalesce(jsonb_agg(q), '[]') INTO v_tw
      FROM (SELECT t.id AS town, t.kind, t.x::double precision AS mx, t.y::double precision AS my, t.r, t.shape, NULL::uuid AS card, t.people,
                   NULL::double precision AS cw, NULL::double precision AS ch,
                   t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fx, t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fy
              FROM public.rpg_map_towns(7, (p_x0 - 3 * g.r)::integer, (p_y0 - 3 * g.r)::integer, (p_cols + 6 * g.r)::integer, (p_rows + 6 * g.r)::integer, NULL) t
             WHERE t.kind IS NOT NULL
            UNION ALL
            SELECT c.id::text, c.place_icon, c.place_x + g.world * floor((p_x0 + p_cols / 2.0 - c.place_x) / g.world + 0.5), c.place_y, NULL, NULL, c.id, NULL,
                   c.place_w / 2.0, c.place_h / 2.0,
                   public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share) / 2.0, public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share) / 2.0
              FROM public.rpg_creatures c
             WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
               AND c.place_penalty IS NOT NULL AND c.place_icon IN ('village', 'town', 'city')
               AND public.rpg_map_touches(p_x0 - 3 * g.r, p_y0 - 3 * g.r, p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r, c.place_x, c.place_y,
                                          public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share),
                                          public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share), g.world::integer)) q;

    IF jsonb_array_length(v_tw) = 0 THEN
      v_c := '[]'::jsonb;
    ELSE
      -- each settlement's streets and plot width, once a transaction
      v_tl := coalesce(nullif(current_setting('rpg.townstreets', true), ''), '{}')::jsonb;
      FOR t IN SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision, shape double precision[],
                                                           card uuid, people integer, cw double precision, ch double precision, fx double precision, fy double precision) LOOP
        CONTINUE WHEN v_tl ? t.town;
        -- every road whose line may cross it (rpg_map_roads over the whole settlement), in a steady order; the line of
        -- each where it comes near the settlement (rpg_map_road_lines, 24 points to its finest bend, so the pieces
        -- between them lie on the road to a few hundredths of a square: n = which point, s = how far along the straight
        -- line between its ends, x, y where the road is), where it passes nearest the middle (t0, along the straight
        -- line from a), the half width of its street, and how far along it houses may stand (lo to hi): the road
        -- itself, and for the one road at a middle no other road reaches, on through the middle to the far side
        WITH rl AS MATERIALIZED (
               SELECT r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b, row_number() OVER (ORDER BY r.class, r.a, r.b, r.ax, r.ay) AS k
                 FROM public.rpg_map_roads(7, floor(t.mx - t.fx)::integer, floor(t.my - t.fy)::integer,
                                           (ceil(2 * t.fx) + 2)::integer, (ceil(2 * t.fy) + 2)::integer, 7, NULL, 0) r),
             ra AS (SELECT array_agg(rl.class ORDER BY rl.k) AS class, array_agg(rl.ax ORDER BY rl.k) AS ax, array_agg(rl.ay ORDER BY rl.k) AS ay,
                           array_agg(rl.bx ORDER BY rl.k) AS bx, array_agg(rl.by ORDER BY rl.k) AS by, array_agg(rl.a ORDER BY rl.k) AS a, array_agg(rl.b ORDER BY rl.k) AS b
                      FROM rl HAVING count(*) > 0),
             lp AS MATERIALIZED (
               SELECT p.i AS k, p.n, p.s, p.x, p.y, p.rest
                 FROM ra CROSS JOIN LATERAL public.rpg_map_road_lines(ra.class, ra.ax, ra.ay, ra.bx, ra.by, ra.a, ra.b, 1, NULL,
                                                                      t.mx - t.fx - g.w1, t.my - t.fy - g.w1, t.mx + t.fx + g.w1, t.my + t.fy + g.w1, 24) p),
             ln AS MATERIALIZED (
               SELECT rl.k, rl.class, rl.ax, rl.ay, rl.bx, rl.by, rl.a, rl.b, l0.len,
                      coalesce((SELECT lp.s FROM lp WHERE lp.k = rl.k ORDER BY power(lp.x - t.mx, 2) + power(lp.y - t.my, 2) LIMIT 1),
                               (t.mx - rl.ax) * (rl.bx - rl.ax) / l0.len + (t.my - rl.ay) * (rl.by - rl.ay) / l0.len) AS t0,
                      CASE rl.class WHEN 1 THEN g.w1 WHEN 2 THEN g.w2 ELSE g.w3 END / 2 AS half,
                      sqrt(power(rl.ax - t.mx, 2) + power(rl.ay - t.my, 2)) < 1 AS at_a,
                      sqrt(power(rl.bx - t.mx, 2) + power(rl.by - t.my, 2)) < 1 AS at_b
                 FROM rl
                CROSS JOIN LATERAL (SELECT sqrt(power(rl.bx - rl.ax, 2) + power(rl.by - rl.ay, 2)) AS len) l0
                WHERE l0.len > 0 AND EXISTS (SELECT 1 FROM lp WHERE lp.k = rl.k)),
             lr AS MATERIALIZED (
               SELECT ln.*,
                      CASE WHEN ln.at_a AND m.n = 1 THEN -greatest(t.fx, t.fy) ELSE 0 END AS lo,
                      CASE WHEN ln.at_b AND m.n = 1 THEN ln.len + greatest(t.fx, t.fy) ELSE ln.len END AS hi
                 FROM ln CROSS JOIN (SELECT count(*) FILTER (WHERE q.at_a OR q.at_b) AS n FROM ln q) m),
             -- how much street runs through it: every line, measured four squares at a time where it lies on the
             -- settlement's ground (a card's plain oval for this sum)
             sl AS (
               SELECT count(*) * 4 AS len
                 FROM lr
                CROSS JOIN LATERAL (SELECT greatest(lr.lo, lr.t0 - greatest(t.fx, t.fy)) AS ts, least(lr.hi, lr.t0 + greatest(t.fx, t.fy)) AS te) e
                CROSS JOIN LATERAL (SELECT array_agg(e.ts + 4 * i + 2 ORDER BY i) AS s FROM generate_series(0, greatest(floor((e.te - e.ts) / 4)::integer - 1, -1)) AS i) q
                CROSS JOIN LATERAL public.rpg_map_road_line(lr.class, lr.ax, lr.ay, lr.bx, lr.by, lr.a, lr.b, 1, q.s) p
                WHERE q.s IS NOT NULL
                  AND CASE WHEN t.card IS NULL
                           THEN sqrt(power(p.x - t.mx, 2) + power(p.y - t.my, 2)) <= public.rpg_map_town_edge(atan2(p.y - t.my, p.x - t.mx), t.r, t.shape)
                           ELSE power((p.x - t.mx) / t.cw, 2) + power((p.y - t.my) / t.ch, 2) <= 1 END),
             -- the plot width, in squares: both sides of the streets shared out among the households (people: a rolled
             -- settlement's own count; a card's ground at its kind's crowding, map_<kind>_density), inside its kind's range
             pw AS (
               SELECT least(greatest(2 * sl.len * g.sq / nullif(h.people / g.household, 0),
                                     (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_plot_' || t.kind || '_low') * g.perch),
                            (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_plot_' || t.kind || '_high') * g.perch) / g.sq AS f
                 FROM sl
                CROSS JOIN LATERAL (SELECT coalesce(t.people::double precision,
                                                    pi() * t.cw * t.ch * g.sq * g.sq / 10000
                                                    * (SELECT s.value FROM public.rpg_settings s
                                                        WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_' || t.kind || '_density')) AS people) h)
        SELECT jsonb_build_object('f', (SELECT pw.f FROM pw),
                                  'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('k', lr.k, 'class', lr.class, 'ax', lr.ax, 'ay', lr.ay, 'bx', lr.bx, 'by', lr.by,
                                                                                         'a', lr.a, 'b', lr.b, 'len', lr.len, 't0', lr.t0, 'half', lr.half, 'lo', lr.lo, 'hi', lr.hi,
                                                                                         'pts', (SELECT jsonb_agg(jsonb_build_array(lp.n, round(lp.s::numeric, 2), round(lp.x::numeric, 2), round(lp.y::numeric, 2)) ORDER BY lp.n)
                                                                                                   FROM lp WHERE lp.k = lr.k)) ORDER BY lr.k)
                                                       FROM lr), '[]'::jsonb))
          INTO v_new;
        v_tl := v_tl || jsonb_build_object(t.town, v_new);
      END LOOP;
      PERFORM set_config('rpg.townstreets', v_tl::text, true);

      -- the plots near the block and the house each holds
      WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                             shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                             fx double precision, fy double precision)),
           lr AS MATERIALIZED (
             SELECT tw.town, tw.kind, (v_tl -> tw.town ->> 'f')::double precision AS f, l.*
               FROM tw CROSS JOIN LATERAL jsonb_to_recordset(v_tl -> tw.town -> 'lines')
                       AS l(k integer, class integer, ax double precision, ay double precision, bx double precision, by double precision, a text, b text,
                            len double precision, t0 double precision, half double precision, lo double precision, hi double precision, pts jsonb)),
           -- the pieces of every line: from one point to the next, and straight on past an end where the street runs on
           sg AS MATERIALIZED (
             SELECT q.town, q.k, q.x0, q.y0, q.x1, q.y1
               FROM (SELECT lr.town, lr.k, p.x, p.y, p.n, lead(p.x) OVER w AS x1, lead(p.y) OVER w AS y1, lead(p.n) OVER w AS n1
                       FROM lr CROSS JOIN LATERAL jsonb_array_elements(lr.pts) AS e(v)
                      CROSS JOIN LATERAL (SELECT (e.v ->> 0)::integer AS n, (e.v ->> 2)::double precision AS x, (e.v ->> 3)::double precision AS y) p
                     WINDOW w AS (PARTITION BY lr.town, lr.k ORDER BY p.n)) q(town, k, x0, y0, n, x1, y1, n1)
              WHERE q.n1 = q.n + 1
             UNION ALL
             SELECT lr.town, lr.k, lr.ax + d.ux * lr.lo, lr.ay + d.uy * lr.lo, lr.ax, lr.ay
               FROM lr CROSS JOIN LATERAL (SELECT (lr.bx - lr.ax) / lr.len AS ux, (lr.by - lr.ay) / lr.len AS uy) d WHERE lr.lo < 0
             UNION ALL
             SELECT lr.town, lr.k, lr.bx, lr.by, lr.ax + d.ux * lr.hi, lr.ay + d.uy * lr.hi
               FROM lr CROSS JOIN LATERAL (SELECT (lr.bx - lr.ax) / lr.len AS ux, (lr.by - lr.ay) / lr.len AS uy) d WHERE lr.hi > lr.len),
           -- how far along each line the plots near the box may lie (three reaches round the block): where its points
           -- and its straight ends come within a street, a setback and a house of the box
           pr AS MATERIALIZED (
             SELECT lr.*, q.tmin - lr.f AS tmin, q.tmax + lr.f AS tmax
               FROM lr
              CROSS JOIN LATERAL (SELECT lr.half + (g.setback_hi + g.vbays_hi * g.bay) / g.sq + g.r AS reach) e
              CROSS JOIN LATERAL (
                SELECT min(u.s) AS tmin, max(u.s) AS tmax
                  FROM (SELECT (pe.v ->> 1)::double precision AS s FROM jsonb_array_elements(lr.pts) AS pe(v)
                         WHERE (pe.v ->> 2)::double precision BETWEEN p_x0 - 3 * g.r - e.reach AND p_x0 + p_cols + 3 * g.r + e.reach
                           AND (pe.v ->> 3)::double precision BETWEEN p_y0 - 3 * g.r - e.reach AND p_y0 + p_rows + 3 * g.r + e.reach
                        UNION ALL
                        SELECT v.s FROM (VALUES (lr.lo), (0::double precision)) AS v(s)
                         WHERE lr.lo < 0 AND public.rpg_seg_box(lr.ax + (lr.bx - lr.ax) / lr.len * lr.lo, lr.ay + (lr.by - lr.ay) / lr.len * lr.lo, lr.ax, lr.ay,
                                                                p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)
                        UNION ALL
                        SELECT v.s FROM (VALUES (lr.len), (lr.hi)) AS v(s)
                         WHERE lr.hi > lr.len AND public.rpg_seg_box(lr.bx, lr.by, lr.ax + (lr.bx - lr.ax) / lr.len * lr.hi, lr.ay + (lr.by - lr.ay) / lr.len * lr.hi,
                                                                     p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)) u) q
              WHERE lr.f > 0 AND q.tmin IS NOT NULL),
           pl AS MATERIALIZED (
             SELECT pr.town, pr.kind, pr.k, pr.class, pr.half, pr.f, j,
                    pr.t0 + (j + 0.5) * pr.f AS tm, s.side, pr.t0 + (j + 0.5) * pr.f < 0 OR pr.t0 + (j + 0.5) * pr.f > pr.len AS cont
               FROM pr
              CROSS JOIN LATERAL generate_series(greatest(ceil((pr.lo - pr.t0) / pr.f - 1e-6), floor((pr.tmin - pr.t0) / pr.f) - 1)::integer,
                                                 least(floor((pr.hi - pr.t0) / pr.f + 1e-6) - 1, ceil((pr.tmax - pr.t0) / pr.f) + 1)::integer) AS j
              CROSS JOIN (VALUES (-1), (1)) AS s(side)),
           -- where the road runs at the middle of each plot (rpg_map_road_line at that count along the line), and the
           -- way it runs there: along it (ux, uy) and across it (nx, ny)
           pq AS (SELECT pl.town, pl.k, array_agg(DISTINCT pl.tm ORDER BY pl.tm) AS tms FROM pl GROUP BY pl.town, pl.k),
           pp AS MATERIALIZED (
             SELECT pq.town, pq.k, pq.tms[p.n] AS tm, p.x, p.y, p.ux, p.uy, -p.uy AS nx, p.ux AS ny
               FROM pq JOIN pr ON pr.town = pq.town AND pr.k = pq.k
              CROSS JOIN LATERAL public.rpg_map_road_line(pr.class, pr.ax, pr.ay, pr.bx, pr.by, pr.a, pr.b, 1, pq.tms) p),
           -- each plot's own rolls (u1 to u9, 0 to 1) at the square in its middle on the road's line
           pu AS MATERIALIZED (
             SELECT pl.*, pp.x AS lx, pp.y AS ly, pp.ux, pp.uy, pp.nx, pp.ny, round(pp.x)::integer AS px, round(pp.y)::integer AS py,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + CASE WHEN pl.side > 0 THEN 10 ELSE 0 END + n,
                                                           round(pp.x)::integer, round(pp.y)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u
               FROM pl JOIN pp ON pp.town = pl.town AND pp.k = pl.k AND pp.tm = pl.tm),
           -- the house of each plot, in metres
           hm AS (
             SELECT pu.*, d.*
               FROM pu
              CROSS JOIN LATERAL (
                SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_storeys_' || pu.kind || '_low') AS s_lo,
                       (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_storeys_' || pu.kind || '_high') AS s_hi) k
              CROSS JOIN LATERAL (
                SELECT (k.s_lo + least(floor((k.s_hi - k.s_lo + 1) * pu.u[3]), k.s_hi - k.s_lo))::integer AS storeys,
                       g.span_lo + (g.span_hi - g.span_lo) * pu.u[1] AS span,
                       CASE WHEN pu.kind = 'village' THEN g.vbays_lo + least(floor((g.vbays_hi - g.vbays_lo + 1) * pu.u[2]), g.vbays_hi - g.vbays_lo)
                            ELSE g.tbays_lo + least(floor((g.tbays_hi - g.tbays_lo + 1) * pu.u[2]), g.tbays_hi - g.tbays_lo) END * g.bay AS length,
                       g.storey_lo + (g.storey_hi - g.storey_lo) * pu.u[4] AS storey,
                       CASE WHEN pu.kind = 'village' THEN g.thatch_lo + (g.thatch_hi - g.thatch_lo) * pu.u[5]
                            ELSE g.tile_lo + (g.tile_hi - g.tile_lo) * pu.u[5] END AS pitch,
                       CASE WHEN pu.kind = 'village' THEN g.setback_hi * pu.u[6] ELSE 0 END AS setback,
                       CASE WHEN pu.kind <> 'village' AND pu.u[7] < 0.5 THEN g.passage ELSE 0 END AS passage) d),
           -- along = along the road, deep = back from it; a village house long side to the lane when its toft leaves
           -- map_house_gap_m beside it, else gable end on; a town or city house fills its plot less any passage
           hs AS (
             SELECT hm.*, a.along, a.deep,
                    CASE WHEN hm.kind = 'village' THEN (hm.f * g.sq - a.along) * (hm.u[7] - 0.5)
                         WHEN hm.u[8] < 0.5 THEN -hm.passage / 2 ELSE hm.passage / 2 END AS off
               FROM hm
              CROSS JOIN LATERAL (
                SELECT CASE WHEN hm.kind <> 'village' THEN hm.f * g.sq - hm.passage
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.length ELSE hm.span END AS along,
                       CASE WHEN hm.kind <> 'village' THEN hm.length
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.span ELSE hm.length END AS deep) a),
           -- in squares on the map: the middle, the way of the ridge and the half sides
           hc AS MATERIALIZED (
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side,
                    'h' || hs.k || '-' || hs.px || '-' || hs.py || CASE WHEN hs.side > 0 THEN 'r' ELSE 'l' END AS id,
                    hs.lx + hs.ux * hs.off / g.sq + hs.nx * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cx,
                    hs.ly + hs.uy * hs.off / g.sq + hs.ny * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cy,
                    CASE WHEN hs.along >= hs.deep THEN hs.ux ELSE hs.nx END AS rx, CASE WHEN hs.along >= hs.deep THEN hs.uy ELSE hs.ny END AS ry,
                    greatest(hs.along, hs.deep) / 2 / g.sq AS hl, least(hs.along, hs.deep) / 2 / g.sq AS hw,
                    hs.storeys * hs.storey AS eaves, hs.pitch, hs.storeys,
                    CASE WHEN hs.kind = 'village' THEN 'thatch' ELSE 'tile' END AS roof
               FROM hs),
           -- the houses in that box that keep clear of every road and street of their settlement (every piece of every
           -- line, half its width from it), each with its place in the order: bigger road first, then the road counted
           -- first, its own road before the street it runs on as, then the plot nearer the middle
           cl AS MATERIALIZED (
             SELECT hc.*, row_number() OVER (PARTITION BY hc.town ORDER BY hc.class, hc.k, hc.cont, abs(hc.j), hc.j, hc.side) AS n
               FROM hc
              WHERE hc.cx BETWEEN p_x0 - 3 * g.r AND p_x0 + p_cols + 3 * g.r AND hc.cy BETWEEN p_y0 - 3 * g.r AND p_y0 + p_rows + 3 * g.r
                AND NOT EXISTS (
                      SELECT 1 FROM sg JOIN lr ON lr.town = sg.town AND lr.k = sg.k
                       CROSS JOIN LATERAL (SELECT lr.half - 0.01 AS wide) w
                       CROSS JOIN LATERAL (SELECT sg.x0 - hc.cx AS x0, sg.y0 - hc.cy AS y0, sg.x1 - hc.cx AS x1, sg.y1 - hc.cy AS y1) e
                       WHERE sg.town = hc.town
                         AND least(sg.x0, sg.x1) <= hc.cx + hc.hl + w.wide AND greatest(sg.x0, sg.x1) >= hc.cx - hc.hl - w.wide
                         AND least(sg.y0, sg.y1) <= hc.cy + hc.hl + w.wide AND greatest(sg.y0, sg.y1) >= hc.cy - hc.hl - w.wide
                         AND public.rpg_seg_box(e.x0 * hc.rx + e.y0 * hc.ry, e.y0 * hc.rx - e.x0 * hc.ry, e.x1 * hc.rx + e.y1 * hc.ry, e.y1 * hc.rx - e.x1 * hc.ry,
                                                -(hc.hl + w.wide), -(hc.hw + w.wide), hc.hl + w.wide, hc.hw + w.wide)))
      -- of those, the ones that reach the block and are clear of the houses before them
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', cl.id, 'town', cl.town, 'kind', cl.kind, 'roof', cl.roof, 'cx', cl.cx, 'cy', cl.cy,
                                                   'ux', cl.rx, 'uy', cl.ry, 'half_len', cl.hl, 'half_wide', cl.hw, 'eaves', cl.eaves,
                                                   'pitch', cl.pitch, 'storeys', cl.storeys) ORDER BY cl.town, cl.n), '[]'::jsonb)
        INTO v_hb
        FROM cl
       WHERE public.rpg_map_rects_meet(cl.cx, cl.cy, cl.rx, cl.ry, cl.hl, cl.hw, p_x0 + p_cols / 2.0, p_y0 + p_rows / 2.0, 1, 0, p_cols / 2.0, p_rows / 2.0)
         AND NOT EXISTS (SELECT 1 FROM cl c2
                          WHERE c2.town = cl.town AND c2.n < cl.n
                            AND public.rpg_map_rects_meet(cl.cx, cl.cy, cl.rx, cl.ry, cl.hl, cl.hw, c2.cx, c2.cy, c2.rx, c2.ry, c2.hl, c2.hw));

      -- whether each stands on its own dry ground, once a transaction: the four corners and the middles of the four
      -- sides, a hair in, on its settlement's ground and not the sea, and no river or lake under them or its middle
      v_ok := coalesce(nullif(current_setting('rpg.houseok', true), ''), '{}')::jsonb;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_hb) h WHERE NOT v_ok ? (h ->> 'id')) THEN
        WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                               shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                               fx double precision, fy double precision)),
             hb AS (SELECT * FROM jsonb_to_recordset(v_hb) AS h(id text, town text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                                half_len double precision, half_wide double precision)
                     WHERE NOT v_ok ? h.id),
             pt AS MATERIALIZED (
               SELECT hb.id, hb.town, q.a * (hb.half_len - 0.01) * hb.ux - q.b * (hb.half_wide - 0.01) * hb.uy + hb.cx AS x,
                      q.a * (hb.half_len - 0.01) * hb.uy + q.b * (hb.half_wide - 0.01) * hb.ux + hb.cy AS y
                 FROM hb CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             -- the land and sea under them, and a card's own edge, read once as a block
             ab AS (SELECT floor(min(pt.x))::integer AS x0, floor(min(pt.y))::integer AS y0,
                           (floor(max(pt.x)) - floor(min(pt.x)) + 1)::integer AS cols, (floor(max(pt.y)) - floor(min(pt.y)) + 1)::integer AS rows
                      FROM pt),
             ht AS MATERIALIZED (SELECT h.x, h.y, h.height FROM ab CROSS JOIN LATERAL public.rpg_map_heights(7, ab.x0, ab.y0, ab.cols, ab.rows) h),
             -- the rivers and lakes under them, read once as a block (step 10a: the whole house, not only its middle)
             wa AS MATERIALIZED (SELECT f.x, f.y FROM ab CROSS JOIN LATERAL public.rpg_map_flow(7, ab.x0, ab.y0, ab.cols, ab.rows) f WHERE f.depth > 0),
             wn AS MATERIALIZED (
               SELECT tw.town, w.x, w.y FROM tw CROSS JOIN ab CROSS JOIN LATERAL public.rpg_map_within(tw.card, 7, ab.x0, ab.y0, ab.cols, ab.rows) w
                WHERE tw.card IS NOT NULL AND EXISTS (SELECT 1 FROM hb WHERE hb.town = tw.town))
        SELECT v_ok || coalesce(jsonb_object_agg(hb.id,
                 NOT EXISTS (SELECT 1 FROM pt
                               LEFT JOIN ht ON ht.x = floor(pt.x) AND ht.y = floor(pt.y)
                              WHERE pt.id = hb.id
                                AND (coalesce(ht.height, -1e9) < g.sea
                                     OR CASE WHEN tw.card IS NULL
                                             THEN sqrt(power(pt.x - tw.mx, 2) + power(pt.y - tw.my, 2)) > public.rpg_map_town_edge(atan2(pt.y - tw.my, pt.x - tw.mx), tw.r, tw.shape)
                                             ELSE NOT EXISTS (SELECT 1 FROM wn WHERE wn.town = tw.town AND wn.x = floor(pt.x) AND wn.y = floor(pt.y)) END))
                 AND NOT EXISTS (SELECT 1 FROM wa WHERE wa.x = floor(hb.cx) AND wa.y = floor(hb.cy))
                 AND NOT EXISTS (SELECT 1 FROM pt JOIN wa ON wa.x = floor(pt.x) AND wa.y = floor(pt.y) WHERE pt.id = hb.id)), '{}'::jsonb)
          INTO v_ok
          FROM hb JOIN tw ON tw.town = hb.town;
        PERFORM set_config('rpg.houseok', v_ok::text, true);
      END IF;
      SELECT coalesce(jsonb_agg(h ORDER BY n), '[]'::jsonb) INTO v_c
        FROM jsonb_array_elements(v_hb) WITH ORDINALITY AS e(h, n)
       WHERE (v_ok ->> (h ->> 'id'))::boolean;
    END IF;
    PERFORM set_config('rpg.houses', jsonb_set(v_all, ARRAY[v_key], v_c)::text, true);
  END IF;
  RETURN QUERY
  SELECT h.id, h.town, h.kind, h.roof, h.cx, h.cy, h.ux, h.uy, h.half_len, h.half_wide, h.eaves, h.pitch, h.storeys
    FROM jsonb_to_recordset(v_c) AS h(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                      half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_path(p_sx integer, p_sy integer, p_gx integer, p_gy integer)
 RETURNS TABLE(n integer, x integer, y integer, class integer, place uuid, stop boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The way a walk goes from p_sx, p_sy to p_gx, p_gy (world squares from 0; step 8b): straight across the land, or
-- along the roads where that is quicker. Off a road walking takes 5/3 as long as on one (Tobler 1993: off a path, 3/5
-- of the speed; map_road_keep), so the way is the one with the fewest steps when each step off a road counts 5/3:
-- straight to the end, or over to a road (to a place it joins, or the nearest point of a stretch of it), along the
-- roads (rpg_map_roads: highways, roads and lanes; and the place cards that are roads, like the Cursed Road) and off
-- again to the end. The roads looked at lie within map_road_plan town squares (7.2 miles) of the start, toward the
-- end; when the end lies farther, the way goes along the roads as far as they help and stops there (stop: the walk
-- ends its turn there and looks again next turn), unless no road helps, when it goes straight, or a stretch the end
-- lies by reaches in, when it goes along it all the way. A walk of one battle
-- grid (12 squares) or less goes straight: the battle grid has its roads as ground.
-- A road wanders (step 10b): each stretch is walked as a chain of points along its line (rpg_map_road_lines, read with
-- the bends half a Region cell long and longer, 864 squares: a point every 216 squares or so), so the way along it is
-- as long as the road, and a walk joins it at the nearest point of that chain. The walk puts its last square on the
-- road to the square (rpg_map_road_snap). A place card that is a road runs straight from end to end.
-- One row a point of the way, from the start (n = 0) to the last: class = how the leg that arrives there is walked
-- (1 to 3 along a road of that size, 4 along the place card place, nothing across the land).
DECLARE
  v_world bigint; v_lt double precision; v_keep double precision; v_reach double precision;
  v_dx bigint; v_tx double precision; v_ty double precision; v_dist double precision;
  v_ex double precision; v_ey double precision; v_far boolean; v_m double precision;
  v_bx0 bigint; v_by0 bigint; v_bx1 bigint; v_by1 bigint; v_cell double precision;
  l_k integer[]; l_ax double precision[]; l_ay double precision[]; l_bx double precision[]; l_by double precision[];
  l_a text[]; l_b text[]; l_p uuid[];
  c_x double precision[]; c_y double precision[]; c_d double precision[]; c_o integer[]; c_n integer[];
  v_id text[]; v_x double precision[]; v_y double precision[]; v_nv integer; v_s integer; v_t integer;
  e_a integer[]; e_b integer[]; e_c double precision[]; e_k integer[]; e_p uuid[]; e_n integer[]; e_ua double precision[]; e_ub double precision[]; v_off integer[];
  v_d double precision[]; v_prev integer[]; v_pe integer[]; v_done boolean[];
  u integer; i integer; j integer; v_best double precision; v_nd double precision;
  v_path integer[] := '{}'; v_cls integer[] := '{}'; v_pls uuid[] := '{}'; v_edg integer[] := '{}'; v_last integer;
BEGIN
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  SELECT l.cell / 4.0 INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = 4;
  SELECT s.value INTO v_lt FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_lattice';
  SELECT s.value INTO v_keep FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_keep';
  SELECT s.value * v_lt INTO v_reach FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_plan';
  -- the end counted the short way round the world from the start
  SELECT l.dx, l.steps INTO v_dx, v_dist FROM public.rpg_map_line(p_sx, p_sy, p_gx, p_gy) l;
  v_tx := p_sx + v_dx; v_ty := p_gy;
  IF v_dist > 12 THEN
    -- the roads looked at: round the stretch from the start toward the end, at most map_road_plan town squares long
    v_far := v_dist > v_reach;
    v_ex := CASE WHEN v_far THEN p_sx + (v_tx - p_sx) * v_reach / v_dist ELSE v_tx END;
    v_ey := CASE WHEN v_far THEN p_sy + (v_ty - p_sy) * v_reach / v_dist ELSE v_ty END;
    v_m := greatest(300, least(0.7 * least(v_dist, v_reach), v_reach / 2));
    v_bx0 := floor(least(p_sx, v_ex) - v_m); v_bx1 := ceil(greatest(p_sx, v_ex) + v_m);
    v_by0 := floor(least(p_sy, v_ey) - v_m); v_by1 := ceil(greatest(p_sy, v_ey) + v_m);
    -- every stretch of road there, and every place card that is a road (it runs from end to end)
    SELECT array_agg(q.k), array_agg(q.ax), array_agg(q.ay), array_agg(q.bx), array_agg(q.by), array_agg(q.a), array_agg(q.b), array_agg(q.p)
      INTO l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b, l_p
      FROM (SELECT r.class AS k, r.ax, r.ay, r.bx, r.by, r.a, r.b, NULL::uuid AS p
              FROM public.rpg_map_roads(7, v_bx0::integer, v_by0::integer, (v_bx1 - v_bx0)::integer, (v_by1 - v_by0)::integer, 7, NULL, 0) r
            UNION ALL
            SELECT 4, e.x0, e.y0, e.x1, e.y1, 'end-' || p.id || '-0', 'end-' || p.id || '-1', p.id
              FROM public.rpg_creatures p
             CROSS JOIN LATERAL (SELECT p.place_x + v_world * floor(((v_bx0 + v_bx1) / 2.0 - p.place_x) / v_world + 0.5) AS cx) m
             CROSS JOIN LATERAL (SELECT CASE WHEN p.place_w >= p.place_h THEN m.cx - p.place_w / 2.0 ELSE m.cx END AS x0,
                                        CASE WHEN p.place_w >= p.place_h THEN p.place_y::double precision ELSE p.place_y - p.place_h / 2.0 END AS y0,
                                        CASE WHEN p.place_w >= p.place_h THEN m.cx + p.place_w / 2.0 ELSE m.cx END AS x1,
                                        CASE WHEN p.place_w >= p.place_h THEN p.place_y::double precision ELSE p.place_y + p.place_h / 2.0 END AS y1) e
             WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL
               AND p.place_penalty IS NOT NULL AND p.place_icon = 'road'
               AND public.rpg_seg_box(e.x0, e.y0, e.x1, e.y1, v_bx0, v_by0, v_bx1, v_by1)) q;
  END IF;
  -- the stretches looked at, kept for the rest of the transaction: the walk puts its last square on one of them
  -- (rpg_map_road_snap) without looking for them again
  PERFORM set_config('rpg.roadplan', coalesce((SELECT jsonb_agg(jsonb_build_array(u.k, u.ax, u.ay, u.bx, u.by, u.a, u.b))
                                                 FROM unnest(l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b) AS u(k, ax, ay, bx, by, a, b) WHERE u.k <= 3), '[]'::jsonb)::text, true);
  IF l_k IS NULL THEN
    -- nothing to look at: straight
    RETURN QUERY SELECT 0, p_sx, p_sy, NULL::integer, NULL::uuid, false UNION ALL SELECT 1, p_gx, p_gy, NULL::integer, NULL::uuid, false;
    RETURN;
  END IF;

  -- the chain of points of each stretch (a road: its line; a place card that is a road: its two ends), all in a row:
  -- c_o = where each stretch starts in the row (from 1), c_n = how many points it has, c_d = the steps along the chain
  -- to each point from its first (the larger of the two gaps, as a walk counts)
  WITH q AS (SELECT u.n, u.k, u.ax, u.ay, u.bx, u.by, u.a, u.b FROM unnest(l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b) WITH ORDINALITY AS u(k, ax, ay, bx, by, a, b, n)),
       ra AS (SELECT array_agg(q.n ORDER BY q.n) AS n, array_agg(q.k ORDER BY q.n) AS k, array_agg(q.ax ORDER BY q.n) AS ax, array_agg(q.ay ORDER BY q.n) AS ay,
                     array_agg(q.bx ORDER BY q.n) AS bx, array_agg(q.by ORDER BY q.n) AS by, array_agg(q.a ORDER BY q.n) AS a, array_agg(q.b ORDER BY q.n) AS b
                FROM q WHERE q.k <= 3 HAVING count(*) > 0),
       pt AS (SELECT ra.n[l.i] AS n, l.n AS j, l.x, l.y FROM ra CROSS JOIN LATERAL public.rpg_map_road_lines(ra.k, ra.ax, ra.ay, ra.bx, ra.by, ra.a, ra.b, v_cell) l
              UNION ALL
              SELECT q.n, 0, q.ax, q.ay FROM q WHERE q.k = 4
              UNION ALL
              SELECT q.n, 1, q.bx, q.by FROM q WHERE q.k = 4),
       st AS (SELECT pt.n, pt.j, pt.x, pt.y, greatest(abs(pt.x - lag(pt.x) OVER w), abs(pt.y - lag(pt.y) OVER w)) AS step
                FROM pt WINDOW w AS (PARTITION BY pt.n ORDER BY pt.j)),
       cd AS (SELECT st.n, st.j, st.x, st.y, sum(st.step) OVER (PARTITION BY st.n ORDER BY st.j) AS d FROM st),
       cn AS (SELECT cd.n, count(*) AS c FROM cd GROUP BY cd.n),
       co AS (SELECT cn.n, cn.c, (sum(cn.c) OVER (ORDER BY cn.n) - cn.c + 1)::integer AS o FROM cn)
  SELECT (SELECT array_agg(cd.x ORDER BY cd.n, cd.j) FROM cd), (SELECT array_agg(cd.y ORDER BY cd.n, cd.j) FROM cd),
         (SELECT array_agg(coalesce(cd.d, 0) ORDER BY cd.n, cd.j) FROM cd),
         (SELECT array_agg(co.o ORDER BY co.n) FROM co), (SELECT array_agg(co.c ORDER BY co.n) FROM co)
    INTO c_x, c_y, c_d, c_o, c_n;

  -- the places: every end of a stretch, the start, the end, and the nearest point of the nearest six stretches to the
  -- start and to the end (where a walk joins a road or leaves it between two places): on the chain of the stretch,
  -- u = how far along it in points (the nearest piece and how far along that piece)
  WITH en AS (SELECT q.id, min(q.x) AS x, min(q.y) AS y
                FROM (SELECT u.a AS id, u.ax AS x, u.ay AS y FROM unnest(l_a, l_ax, l_ay) AS u(a, ax, ay)
                      UNION ALL SELECT u.b, u.bx, u.by FROM unnest(l_b, l_bx, l_by) AS u(b, bx, by)) q GROUP BY q.id),
       sg AS (SELECT s.n AS seg, g.i - 1 AS v, c_x[c_o[s.n] + g.i - 1] AS ax, c_y[c_o[s.n] + g.i - 1] AS ay, c_x[c_o[s.n] + g.i] AS bx, c_y[c_o[s.n] + g.i] AS by
                FROM unnest(l_k) WITH ORDINALITY AS s(k, n) CROSS JOIN LATERAL generate_series(1, c_n[s.n] - 1) AS g(i)),
       pj AS (SELECT DISTINCT ON (w.who, sg.seg) w.who, w.n0, sg.seg, round((sg.v + t.t)::numeric, 6) AS u,
                     sg.ax + t.t * (sg.bx - sg.ax) AS px, sg.ay + t.t * (sg.by - sg.ay) AS py,
                     greatest(abs(sg.ax + t.t * (sg.bx - sg.ax) - w.wx), abs(sg.ay + t.t * (sg.by - sg.ay) - w.wy)) AS gap
                FROM (VALUES ('S', 0, p_sx::double precision, p_sy::double precision), ('T', 1, v_tx, v_ty)) AS w(who, n0, wx, wy)
               CROSS JOIN sg
               CROSS JOIN LATERAL (SELECT CASE WHEN power(sg.bx - sg.ax, 2) + power(sg.by - sg.ay, 2) = 0 THEN 0
                                               ELSE least(greatest(((w.wx - sg.ax) * (sg.bx - sg.ax) + (w.wy - sg.ay) * (sg.by - sg.ay))
                                                                   / (power(sg.bx - sg.ax, 2) + power(sg.by - sg.ay, 2)), 0), 1) END AS t) t
               ORDER BY w.who, sg.seg, greatest(abs(sg.ax + t.t * (sg.bx - sg.ax) - w.wx), abs(sg.ay + t.t * (sg.by - sg.ay) - w.wy)), sg.v),
       pk AS (SELECT pj.*, row_number() OVER (PARTITION BY pj.who ORDER BY pj.gap, pj.seg) AS r FROM pj),
       al AS (SELECT en.id, en.x, en.y, 0 AS o FROM en
              UNION ALL SELECT 'S', p_sx, p_sy, 1
              UNION ALL SELECT 'T', v_tx, v_ty, 2
              UNION ALL SELECT 'p' || pk.who || '-' || pk.seg || '-' || pk.u, pk.px, pk.py, 3 FROM pk WHERE pk.r <= 6)
  SELECT array_agg(al.id ORDER BY al.o, al.id), array_agg(al.x ORDER BY al.o, al.id), array_agg(al.y ORDER BY al.o, al.id)
    INTO v_id, v_x, v_y FROM al;
  v_nv := cardinality(v_id);
  v_s := array_position(v_id, 'S'); v_t := array_position(v_id, 'T');

  -- the ways between places, each its cost in steps (along a chain, the steps along it; across the land, the larger of
  -- the two gaps: a diagonal step costs the same as a straight one), a step off the road counted 5/3 (1 / map_road_keep);
  -- both ways, grouped by the place they leave. A way along a stretch carries the stretch and where on its chain it
  -- starts and ends (ua, ub)
  WITH ix AS (SELECT u.id, u.i::integer AS i FROM unnest(v_id) WITH ORDINALITY AS u(id, i)),
       sg AS (SELECT s.*, a.i AS ia, b.i AS ib, (c_n[s.n] - 1)::double precision AS ul, c_d[c_o[s.n] + c_n[s.n] - 1] AS len
                FROM unnest(l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b, l_p) WITH ORDINALITY AS s(k, ax, ay, bx, by, a, b, p, n)
                JOIN ix a ON a.id = s.a JOIN ix b ON b.id = s.b),
       -- the join points: which stretch and how far along its chain
       jp AS (SELECT ix.i, split_part(ix.id, '-', 2)::integer AS n, split_part(ix.id, '-', 3)::double precision AS u, split_part(ix.id, '-', 1) AS who
                FROM ix WHERE ix.id LIKE 'p%-%'),
       ed AS (
         -- along a stretch of road; along a place card that is a road at its own ground
         SELECT sg.ia AS a, sg.ib AS b, sg.len * (1 + coalesce(g.penalty, 0) / 100.0) AS c, sg.k, sg.p, sg.n::integer AS sn, 0::double precision AS ua, sg.ul AS ub
           FROM sg LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL
         UNION ALL
         -- the ends of a place card that is a road join the places within 400 squares of them
         SELECT a.i, b.i, greatest(abs(v_x[b.i] - v_x[a.i]), abs(v_y[b.i] - v_y[a.i])) / v_keep, NULL, NULL, NULL, NULL, NULL
           FROM ix a JOIN ix b ON a.id LIKE 'end-%' AND b.i <> a.i AND b.id NOT IN ('S', 'T') AND b.id NOT LIKE 'p%-%'
          WHERE greatest(abs(v_x[b.i] - v_x[a.i]), abs(v_y[b.i] - v_y[a.i])) <= 400
         UNION ALL
         -- the start straight to the end
         SELECT v_s, v_t, v_dist / v_keep, NULL, NULL, NULL, NULL, NULL
         UNION ALL
         -- the start over to its eight nearest places
         SELECT v_s, q.i, q.c / v_keep, NULL, NULL, NULL, NULL, NULL
           FROM (SELECT ix.i, greatest(abs(v_x[ix.i] - p_sx), abs(v_y[ix.i] - p_sy)) AS c FROM ix WHERE ix.id NOT IN ('S', 'T') AND ix.id NOT LIKE 'p%-%' ORDER BY 2, 1 LIMIT 8) q
         UNION ALL
         -- the eight nearest places over to the end; every place when the end lies past the roads looked at
         SELECT q.i, v_t, q.c / v_keep, NULL, NULL, NULL, NULL, NULL
           FROM (SELECT ix.i, greatest(abs(v_x[ix.i] - v_tx), abs(v_y[ix.i] - v_ty)) AS c FROM ix WHERE ix.id NOT IN ('S', 'T') AND ix.id NOT LIKE 'p%-%'
                  ORDER BY 2, 1 LIMIT CASE WHEN v_far THEN NULL ELSE 8 END) q
         UNION ALL
         -- the start or the end over to the nearest point of a stretch, then along the stretch to either end of it
         SELECT CASE WHEN jp.who = 'pS' THEN v_s ELSE v_t END, jp.i,
                greatest(abs(v_x[jp.i] - CASE WHEN jp.who = 'pS' THEN p_sx ELSE v_tx END),
                         abs(v_y[jp.i] - CASE WHEN jp.who = 'pS' THEN p_sy ELSE v_ty END)) / v_keep, NULL, NULL, NULL, NULL, NULL
           FROM jp
         UNION ALL
         SELECT jp.i, e.i, abs(e.d - d.d) * (1 + coalesce(g.penalty, 0) / 100.0), sg.k, sg.p, sg.n::integer, jp.u, e.u
           FROM jp JOIN sg ON sg.n = jp.n
          CROSS JOIN LATERAL (SELECT c_d[c_o[sg.n] + floor(jp.u)::integer] + (jp.u - floor(jp.u)) * (c_d[c_o[sg.n] + least(floor(jp.u)::integer + 1, c_n[sg.n] - 1)] - c_d[c_o[sg.n] + floor(jp.u)::integer]) AS d) d
          CROSS JOIN LATERAL (VALUES (sg.ia, 0::double precision, 0::double precision), (sg.ib, sg.ul, sg.len)) AS e(i, u, d)
           LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL
         UNION ALL
         -- the start and the end on the same stretch: along it from one to the other
         SELECT a.i, b.i, abs(da.d - db.d) * (1 + coalesce(g.penalty, 0) / 100.0), sg.k, sg.p, sg.n::integer, a.u, b.u
           FROM jp a JOIN jp b ON a.who = 'pS' AND b.who = 'pT' AND b.n = a.n
           JOIN sg ON sg.n = a.n
          CROSS JOIN LATERAL (SELECT c_d[c_o[sg.n] + floor(a.u)::integer] + (a.u - floor(a.u)) * (c_d[c_o[sg.n] + least(floor(a.u)::integer + 1, c_n[sg.n] - 1)] - c_d[c_o[sg.n] + floor(a.u)::integer]) AS d) da
          CROSS JOIN LATERAL (SELECT c_d[c_o[sg.n] + floor(b.u)::integer] + (b.u - floor(b.u)) * (c_d[c_o[sg.n] + least(floor(b.u)::integer + 1, c_n[sg.n] - 1)] - c_d[c_o[sg.n] + floor(b.u)::integer]) AS d) db
           LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL),
       bw AS (SELECT ed.a, ed.b, ed.c, ed.k, ed.p, ed.sn, ed.ua, ed.ub FROM ed UNION ALL SELECT ed.b, ed.a, ed.c, ed.k, ed.p, ed.sn, ed.ub, ed.ua FROM ed),
       nb AS (SELECT bw.*, row_number() OVER (ORDER BY bw.a, bw.b, bw.c)::integer AS j FROM bw)
  SELECT array_agg(nb.a ORDER BY nb.j), array_agg(nb.b ORDER BY nb.j), array_agg(nb.c ORDER BY nb.j), array_agg(nb.k ORDER BY nb.j), array_agg(nb.p ORDER BY nb.j),
         array_agg(nb.sn ORDER BY nb.j), array_agg(nb.ua ORDER BY nb.j), array_agg(nb.ub ORDER BY nb.j),
         (SELECT array_agg(coalesce((SELECT min(q.j) FROM nb q WHERE q.a >= g), (SELECT count(*) FROM nb) + 1)::integer ORDER BY g)
            FROM generate_series(1, v_nv + 1) AS g)
    INTO e_a, e_b, e_c, e_k, e_p, e_n, e_ua, e_ub, v_off
    FROM nb;

  -- the cheapest way from the start to the end (Dijkstra 1959)
  v_d := array_fill(1e18::double precision, ARRAY[v_nv]); v_prev := array_fill(0, ARRAY[v_nv]); v_pe := array_fill(0, ARRAY[v_nv]);
  v_done := array_fill(false, ARRAY[v_nv]);
  v_d[v_s] := 0;
  LOOP
    u := 0; v_best := 1e18;
    FOR i IN 1 .. v_nv LOOP
      IF NOT v_done[i] AND v_d[i] < v_best THEN v_best := v_d[i]; u := i; END IF;
    END LOOP;
    EXIT WHEN u = 0 OR u = v_t;
    v_done[u] := true;
    FOR j IN v_off[u] .. v_off[u + 1] - 1 LOOP
      v_nd := v_best + e_c[j];
      IF v_nd < v_d[e_b[j]] THEN v_d[e_b[j]] := v_nd; v_prev[e_b[j]] := u; v_pe[e_b[j]] := j; END IF;
    END LOOP;
  END LOOP;

  -- the way back from the end
  u := v_t;
  WHILE u <> 0 AND u <> v_s LOOP
    v_path := u || v_path; v_cls := e_k[v_pe[u]] || v_cls; v_pls := e_p[v_pe[u]] || v_pls; v_edg := v_pe[u] || v_edg;
    u := v_prev[u];
  END LOOP;
  -- no road on the way: straight
  IF u = 0 OR NOT EXISTS (SELECT 1 FROM unnest(v_cls) AS k(k) WHERE k.k IS NOT NULL) THEN
    RETURN QUERY SELECT 0, p_sx, p_sy, NULL::integer, NULL::uuid, false UNION ALL SELECT 1, p_gx, p_gy, NULL::integer, NULL::uuid, false;
    RETURN;
  END IF;
  -- when the end lies past the roads looked at and the way leaves the roads for it from a place (not from a point of a
  -- stretch the end lies by), the way stops where it leaves the last road
  v_last := cardinality(v_path);
  IF v_far AND v_last > 1 AND v_id[v_path[v_last - 1]] NOT LIKE 'pT-%' THEN
    WHILE v_last > 0 AND v_cls[v_last] IS NULL LOOP v_last := v_last - 1; END LOOP;
  ELSE
    v_far := false;
  END IF;
  RETURN QUERY
  -- each leg of the way: along a stretch, the points of its chain between where the leg joins it and where it leaves
  -- it, then the place it arrives at
  WITH lg AS (SELECT q.i, v_path[q.i] AS node, v_cls[q.i] AS k, v_pls[q.i] AS p, e_n[v_edg[q.i]] AS sn, e_ua[v_edg[q.i]] AS ua, e_ub[v_edg[q.i]] AS ub
                FROM generate_series(1, v_last) AS q(i)),
       pt AS (SELECT 0 AS i, 0 AS j, p_sx::bigint AS x, p_sy::bigint AS y, NULL::integer AS k, NULL::uuid AS p
              UNION ALL
              SELECT lg.i, CASE WHEN lg.ua < lg.ub THEN v.v - floor(lg.ua)::integer ELSE floor(lg.ua)::integer - v.v END,
                     round(c_x[c_o[lg.sn] + v.v])::bigint, round(c_y[c_o[lg.sn] + v.v])::bigint, lg.k, lg.p
                FROM lg
               CROSS JOIN LATERAL generate_series(CASE WHEN lg.ua < lg.ub THEN floor(lg.ua)::integer + 1 ELSE ceil(lg.ub)::integer END,
                                                  CASE WHEN lg.ua < lg.ub THEN ceil(lg.ub)::integer - 1 ELSE floor(lg.ua)::integer END) AS v(v)
               WHERE lg.sn IS NOT NULL AND (lg.ua < lg.ub AND v.v > lg.ua AND v.v < lg.ub OR lg.ua > lg.ub AND v.v < lg.ua AND v.v > lg.ub)
              UNION ALL
              SELECT lg.i, 1000000, CASE WHEN lg.node = v_t THEN p_sx + v_dx ELSE round(v_x[lg.node])::bigint END,
                     CASE WHEN lg.node = v_t THEN p_gy::bigint ELSE round(v_y[lg.node])::bigint END, lg.k, lg.p
                FROM lg),
       -- two points of the way on one square are one
       dd AS (SELECT pt.*, lag(pt.x) OVER (ORDER BY pt.i, pt.j) AS px, lag(pt.y) OVER (ORDER BY pt.i, pt.j) AS py FROM pt),
       kp AS (SELECT dd.* FROM dd WHERE dd.i = 0 OR NOT (dd.x = dd.px AND dd.y = dd.py))
  SELECT (row_number() OVER (ORDER BY kp.i, kp.j) - 1)::integer, mod(kp.x + v_world, v_world)::integer, kp.y::integer, kp.k, kp.p,
         v_far AND kp.i = max(kp.i) OVER () AND kp.j = max(kp.j) OVER (PARTITION BY kp.i)
    FROM kp ORDER BY kp.i, kp.j;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece walks toward a world square (p_x, p_y counted from 1, as pieces stand; the map works from 0 inside) on
-- its turn, the whole way in one go: the same movement rule as a fight, at every level (Peter 2026-10-01). Every
-- square entered takes move_ticks (5) at Speed 10 times 1 plus the percent of time it adds (its ground's range,
-- rpg_map_band, at how hard its cell is, rpg_map_hard; a cell coarser than the City grid is the average square of its
-- ground), faster or slower by Speed (rpg_ticks_at: base x 20 / (10 + Speed)). Base time is kept in hundredths of a
-- tick. A tick is 1/6 of a second (Peter 2026-10-03, 1B), so open land (+5% on average) goes at about 2.9 miles an
-- hour at Speed 10.
-- The walk runs straight (rpg_map_line), or along the roads where that is quicker (step 8b, rpg_map_road_path: off a
-- road walking takes 5/3 as long, Tobler 1993): leg by leg from place to place, the ground from rpg_map_route_path,
-- looked at closer where the sea starts. A leg along a road is walked on the road: road ground (rpg_map_band road,
-- +0% to +10%), a mountain road over mountains (pass), the ground of the road card itself along a place card that is a road,
-- the streets in a village, town or city and the ground of an open place it crosses; snow and ice stay snow and ice;
-- where a road meets a river or a lake it crosses it (a bridge, a ford or a ferry), walked as the road; the sea stops
-- it. It stops:
--   at the shore: nobody walks into the sea (2A), nor into water too rough to swim, nor ends a walk in water too deep
--   to wade; the piece stands on the last dry square before it;
--   water too deep to wade is swum (step 7b): each square takes map_swim_pct (170) more time, and every round_ticks (20)
--   in the water the site rolls the swimmer's Swimming (Swimming with Gear with swimming gear on) against the water's
--   pull there (rpg_map_swim_difficulty). A miss puts them under: a round lost, and they roll again; under longer than
--   swim_breath_ticks (180) without breathing water, every tick costs vitality at a full bar per swim_drown_ticks (540).
--   Once in the water they swim on until out of it, past the end of the walking day if need be; if they go down
--   (0 vitality) the walk stops there, in the water. The rolls train the skill like any roll (all their points at once);
--   a mountain cliff is climbed (step 7c): on the battle grid each cliff square (rpg_map_steep, rpg_map_cliff_angle)
--   takes its climb's time (rpg_map_climb) and a Climbing roll (Climbing with Gear with climbing gear on) against its
--   difficulty (a walk read in coarser runs, longer than 72 squares, picks its way round cliffs: the mountain's own time
--   allows for that). A miss is a fall the height of the square ((height / climb_fall_down_m, 15 m) squared of their vitality) and the climb again; if
--   they go down the walk stops at the foot of that cliff. Climbing trains like swimming;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   at the end of the roads it looked at, when the square it is heading for lies farther (rpg_map_road_path stop): the
--   square it was heading for is kept, as when the day runs out, and the next turn looks again from there;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it, no house on it), stepping back along the walk
-- if it must. Houses (step 8c) are walked round, along the streets and yards between them: a walk reads a village,
-- town or city as its own ground, and climbing a house is a move on the fight board.
-- The time walked plus any camp is the turn (turn_move_ticks), and the turn passes on (rpg_session_next_turn).
-- Pieces stand on world squares counted from 1 (pos_x = square + 1), like squares on a fight board.
DECLARE
  v_sid uuid; v_p record; v_r record; v_world integer; v_down integer;
  v_tph integer; v_day integer; v_camp integer; v_mt integer; v_even numeric; v_speed numeric; v_ign boolean;
  v_left integer; v_basemax bigint; v_steps integer; v_kmax integer; v_reach integer := 0;
  v_pen integer; v_b integer; v_n integer; v_base bigint := 0; v_why text;
  v_rf integer[] := '{}'; v_rt integer[] := '{}'; v_rb integer[] := '{}';
  v_k integer := 0; v_lo integer; v_hi integer; i integer;
  v_from integer; v_cut integer; v_pass integer; v_lvl integer; v_sea_from integer; v_sea_to integer;
  v_sx integer; v_sy integer; v_tx integer; v_ty integer;
  v_walk integer := 0; v_camped boolean; v_arrived boolean; v_text text; v_next jsonb;
  v_gx integer; v_gy integer; v_hx integer; v_hy integer; v_cards uuid[]; v_t0 integer; v_t1 integer; v_h0 integer; v_haunt integer;
  v_hour integer; v_d100 integer; v_cell bigint; v_wd double precision; v_wl integer; v_deep integer[]; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid; v_chance integer; v_cp uuid; v_gap integer;
  v_wc double precision; v_swim boolean; v_dif numeric; v_rtk integer; v_breath integer; v_drown integer; v_lost numeric; v_need2 numeric;
  v_sw_in boolean := false; v_sw_clock numeric := 0; v_sw_next numeric := 0; v_sw_under integer := 0; v_sw_long integer := 0; v_sw_dips integer := 0;
  v_sw_rolls integer := 0; v_sw_points numeric := 0; v_sw_harmt integer := 0; v_sw_harm integer := 0; v_sw_key text; v_sw_skill numeric; v_sw_gear boolean;
  v_sw_breathes boolean; v_sw_left integer; v_sw_max integer; v_sw_maxdif numeric := 0; v_sw_val numeric;
  v_cliff double precision; v_cl_rise double precision; v_cl_dif numeric; v_cl_key text; v_cl_skill numeric; v_cl_gear boolean;
  v_cl_rolls integer := 0; v_cl_points numeric := 0; v_cl_falls integer := 0; v_cl_harm integer := 0; v_cl_count integer := 0; v_cl_maxdif numeric := 0;
  v_cl_n integer; v_cl_extra numeric; v_cl_try bigint; v_cl_left integer; v_cl_max integer; v_fixed bigint := 0; j integer;
  v_wx integer[]; v_wy integer[]; v_wk integer[]; v_wp uuid[]; v_stop boolean; v_cum integer[]; v_lk integer; v_kind text; v_place uuid;
  v_onroad integer := 0; v_ex integer; v_ey integer; v_house boolean := false; v_nx integer; v_ny integer;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_world OR p_y NOT BETWEEN 1 AND v_down THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1; v_gx := p_x - 1; v_gy := p_y - 1;
  v_haunt := v_p.haunt_ticks; v_chance := public.rpg_setting('encounter_chance')::integer;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_mt := public.rpg_setting('move_ticks')::integer;
  v_even := public.rpg_setting('speed_even');
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_rtk := public.rpg_setting('round_ticks')::integer;
  v_breath := public.rpg_setting('swim_breath_ticks')::integer;
  v_drown := public.rpg_setting('swim_drown_ticks')::integer;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  -- the way: straight, or along the roads (rpg_map_road_path): its points, how each leg is walked (v_wk[i + 1] for the
  -- leg from point i to point i + 1), and the steps walked before each point
  SELECT array_agg(r.x ORDER BY r.n), array_agg(r.y ORDER BY r.n), array_agg(r.class ORDER BY r.n), array_agg(r.place ORDER BY r.n), coalesce(bool_or(r.stop), false)
    INTO v_wx, v_wy, v_wk, v_wp, v_stop
    FROM public.rpg_map_road_path(v_sx, v_sy, v_gx, v_gy) r;
  SELECT array_agg(q.c ORDER BY q.i) INTO v_cum
    FROM (SELECT g.i, coalesce(sum(l.steps) OVER (ORDER BY g.i), 0)::integer AS c
            FROM generate_series(1, cardinality(v_wx)) AS g(i)
            LEFT JOIN LATERAL public.rpg_map_line(v_wx[g.i - 1], v_wy[g.i - 1], v_wx[g.i], v_wy[g.i]) l ON g.i > 1) q;
  v_steps := v_cum[cardinality(v_cum)];
  -- the rivers too deep to wade in their middles (great rivers and rivers): a coarse grid that only draws them as a
  -- line through a cell looks closer there, like at the sea
  SELECT coalesce(array_agg(k), '{}') INTO v_deep FROM generate_series(2, 5) AS k
   WHERE public.rpg_setting('map_river_' || k || '_depth') >= public.rpg_setting('map_swim_depth');
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even) * 100)::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax / 100.0) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / (v_mt * 100))::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 80 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route_path(v_wx, v_wy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_path_at(v_wx, v_wy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0; v_wc := 0; v_swim := false;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- on a leg along a road, the road (step 8b): road ground, also over a river or a lake (its crossing); a mountain
      -- road over mountains; the ground of a road card; the streets of a village, town or city, an open place, snow and
      -- ice and the sea stay what they are
      v_lk := v_wk[v_r.leg + 1]; v_kind := v_r.kind; v_place := v_r.place_id;
      IF v_lk = 4 AND v_kind <> 'sea' THEN v_kind := 'place'; v_place := v_wp[v_r.leg + 1];
      ELSIF v_lk IS NOT NULL AND v_kind = 'mountains' THEN v_kind := 'pass';
      ELSIF v_lk IS NOT NULL AND v_kind NOT IN ('sea', 'ice', 'town', 'place', 'pass') THEN v_kind := 'road';
      END IF;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_kind IN ('water', 'deep') OR (v_r.level < 7 AND v_lk IS NULL) THEN
        SELECT w.depth, w.line, w.current INTO v_wd, v_wl, v_wc
          FROM public.rpg_map_flow(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF v_kind = 'deep' AND v_r.level = 7 THEN
        -- water too deep to wade, on the battle grid: swum (step 7b), unless it pulls too hard to swim or the walk
        -- would end in it (then it stops at the water's edge)
        v_dif := public.rpg_map_swim_difficulty(v_wc);
        IF v_dif IS NOT NULL AND v_r.k_to < v_steps THEN v_pen := public.rpg_map_wade_pct(v_wd); v_swim := true; END IF;
      -- a road crosses rivers: only off the road is a deep river looked at closer
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep) AND v_lk IS NULL) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_kind, v_place) b;
      END IF;
      -- a cliff on the battle grid: climbed, at the time its climb takes
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_kind = 'mountains' AND v_r.level = 7 THEN
        SELECT public.rpg_map_cliff_angle(t.steep) INTO v_cliff FROM public.rpg_map_steep(7, v_hx - 1, v_hy - 1, 1, 1) t;
        IF v_cliff IS NOT NULL THEN SELECT m.pct, m.rise, m.difficulty INTO v_pen, v_cl_rise, v_cl_dif FROM public.rpg_map_climb(v_cliff) m; END IF;
      END IF;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (100 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := greatest(least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer), 0);
      -- once in the water a swimmer swims on until out of it, past the end of the walking day if need be
      IF v_swim AND v_sw_in THEN v_n := v_r.k_to - v_r.k_from + 1; END IF;
      IF NOT v_swim AND v_n > 0 THEN v_sw_in := false; v_sw_under := 0; END IF;
      IF v_swim AND v_n > 0 THEN
        IF NOT v_sw_in THEN
          v_sw_in := true; v_sw_clock := 0; v_sw_next := v_rtk; v_sw_under := 0;
          IF v_sw_key IS NULL THEN
            -- what they swim with: swimming gear on and Swimming with Gear open, else Swimming; a skill not on the
            -- sheet swims as 0 (only a 100 keeps them up) and trains nothing
            v_sw_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'swim_gear')
                         AND public.rpg_participant_value(p_participant_id, 'swim_gear') IS NOT NULL;
            v_sw_key := CASE WHEN v_sw_gear THEN 'swim_gear' ELSE 'WM' END;
            v_sw_skill := public.rpg_participant_value(p_participant_id, v_sw_key);
            v_sw_breathes := EXISTS (SELECT 1 FROM public.rpg_characters ch
                                      CROSS JOIN LATERAL unnest(public.rpg_template_chain(ch.template_id)) AS t(id)
                                      JOIN public.rpg_creatures c ON c.id = t.id
                                     WHERE ch.id = v_p.character_id AND c.breathes_water);
            v_sw_left := (public.rpg_participant_vitality(p_participant_id)->>'left')::integer;
            v_sw_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
          END IF;
        END IF;
        v_sw_maxdif := greatest(v_sw_maxdif, v_dif);
        v_lost := 0;
        v_sw_clock := v_sw_clock + v_n * v_b / 100.0 * 2 * v_even / (v_even + v_speed);
        WHILE v_sw_clock >= v_sw_next LOOP
          v_d100 := floor(random() * 100)::integer + 1;
          v_need2 := (public.rpg_needed(coalesce(v_sw_skill, 0), v_dif)->>'needed')::numeric;
          v_sw_rolls := v_sw_rolls + 1;
          v_sw_points := v_sw_points + v_d100 * v_need2 / 100;
          IF v_d100 >= v_need2 THEN
            v_sw_under := 0;
          ELSE
            -- under: a round lost, and the breath runs down
            IF v_sw_under = 0 THEN v_sw_dips := v_sw_dips + 1; END IF;
            v_sw_under := v_sw_under + v_rtk; v_sw_long := greatest(v_sw_long, v_sw_under);
            IF NOT v_sw_breathes AND v_sw_under > v_breath THEN v_sw_harmt := v_sw_harmt + least(v_rtk, v_sw_under - v_breath); END IF;
            v_lost := v_lost + v_rtk;
            v_sw_clock := v_sw_clock + v_rtk;
            IF ceil(v_sw_max * v_sw_harmt::numeric / v_drown) >= v_sw_left THEN v_why := 'drown'; END IF;
          END IF;
          v_sw_next := v_sw_next + v_rtk;
          EXIT WHEN v_why = 'drown';
        END LOOP;
        -- the time lost under water, in base time, on this stretch
        v_b := v_b + ceil(v_lost * (v_even + v_speed) / (2 * v_even) * 100 / v_n)::integer;
      END IF;
      -- a cliff on this battle-grid square: climbed
      IF v_n > 0 AND v_cliff IS NOT NULL THEN
        v_cl_n := v_n;
        IF v_cl_n > 0 AND v_cl_key IS NULL THEN
          v_cl_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
                       AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
          v_cl_key := CASE WHEN v_cl_gear THEN 'climb_gear' ELSE 'CL' END;
          v_cl_skill := public.rpg_participant_value(p_participant_id, v_cl_key);
          v_cl_left := (public.rpg_participant_vitality(p_participant_id)->>'left')::integer - v_sw_harm;
          v_cl_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
        END IF;
        v_cl_extra := 0;
        FOR j IN 1 .. coalesce(v_cl_n, 0) LOOP
          v_cl_try := v_b;
          v_cl_count := v_cl_count + 1; v_cl_maxdif := greatest(v_cl_maxdif, v_cl_dif);
          LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_need2 := (public.rpg_needed(coalesce(v_cl_skill, 0), v_cl_dif)->>'needed')::numeric;
            v_cl_rolls := v_cl_rolls + 1;
            v_cl_points := v_cl_points + v_d100 * v_need2 / 100;
            EXIT WHEN v_d100 >= v_need2;
            -- a slip: a fall the height of the square, and the climb again
            v_cl_falls := v_cl_falls + 1;
            v_cl_harm := v_cl_harm + greatest(ceil(v_cl_max * power(v_cl_rise / public.rpg_setting('climb_fall_down_m')::double precision, 2))::integer, 1);
            IF v_cl_harm >= v_cl_left THEN v_why := 'fell'; EXIT; END IF;
            v_cl_extra := v_cl_extra + v_cl_try;
          END LOOP;
          EXIT WHEN v_why = 'fell';
        END LOOP;
        IF v_why = 'fell' THEN
          -- down at the foot of that cliff: the time spent there counts, the squares past it are not walked
          v_fixed := v_fixed + ceil(v_cl_extra)::bigint;
          v_n := 0;
        ELSIF v_n > 0 THEN
          v_b := v_b + ceil(v_cl_extra / v_n)::integer;
        END IF;
      END IF;
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A); none in the water
      IF v_n > 0 AND NOT v_swim AND v_why IS DISTINCT FROM 'fell' THEN
        v_cards := public.rpg_map_haunters(v_hx, v_hy);
        IF v_cards IS NOT NULL THEN
          v_t0 := public.rpg_ticks_at(v_speed, v_base / 100.0);
          v_t1 := public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0);
          v_h0 := v_haunt;
          v_haunt := v_haunt + (v_t1 - v_t0);
          FOR v_hour IN (v_h0 / v_tph) + 1 .. (v_haunt / v_tph) LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_rolls := v_rolls || v_d100;
            IF v_d100 <= v_chance THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) * 100 / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0) - v_t0;
              v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
              v_why := 'meet';
              EXIT;
            END IF;
          END LOOP;
        END IF;
      END IF;
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b;
      v_base := v_base + v_n::bigint * v_b;
      v_reach := v_r.k_from + v_n - 1;
      EXIT WHEN v_why IN ('meet', 'drown', 'fell');
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSIF v_why IS NULL AND v_sw_in AND v_cut < v_steps THEN
      -- still in the water when the day's steps ran out: swim on, a stretch at a time
      v_from := v_cut + 1; v_cut := least(v_steps, v_cut + 72);
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;
  -- at the end of the roads it looked at, short of where it is heading
  IF v_why IS NULL AND v_stop THEN v_why := 'way'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back; someone
  -- who went down in the water stays where they went down
  IF v_why = 'drown' THEN v_k := v_reach; END IF;
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_path_at(v_wx, v_wy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux),
         c AS MATERIALIZED (SELECT c.* FROM bb CROSS JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c),
         -- the houses there (step 8c), only where a village, town, city or place is
         hs AS MATERIALIZED (SELECT b.x, b.y FROM bb CROSS JOIN LATERAL public.rpg_map_building_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) b
                              WHERE EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place')))
    SELECT max(ux.k) INTO v_k
      FROM ux JOIN c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind NOT IN ('sea', 'deep')
       AND NOT EXISTS (SELECT 1 FROM hs WHERE hs.x = ux.ux AND hs.y = ux.y)
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  -- a house where the walk was heading (step 8c): it stops in front of it
  IF v_k > 0 AND v_k < v_reach AND v_why IS DISTINCT FROM 'drown' THEN
    SELECT EXISTS (SELECT 1 FROM public.rpg_map_path_at(v_wx, v_wy, v_reach) s
                    CROSS JOIN LATERAL public.rpg_map_building_cells(7, s.x, s.y, 1, 1) b) INTO v_house;
  END IF;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, (v_base + v_fixed) / 100.0);
  v_arrived := v_k = v_steps AND NOT v_stop;
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') NOT IN ('drown', 'fell') AND v_p.day_walk_ticks + v_walk >= v_day);
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone or a house is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_path_at(v_wx, v_wy, v_k) s; END IF;
  -- the end square on the road itself (step 10b): the way along a road is a chain of points 216 squares or so apart
  -- (rpg_map_road_path), so a walk that ends on a leg along a road moves its last square to the nearest square of the
  -- road (rpg_map_road_snap) when that square is dry land (rpg_map_heights), not a river too deep to wade
  -- (rpg_map_flow), not a house and free
  IF v_k > 0 AND coalesce(v_why, '') <> 'drown' THEN
    SELECT v_wk[g.l + 1] INTO v_lk FROM generate_series(1, cardinality(v_wx) - 1) AS g(l) WHERE v_cum[g.l] < v_k AND v_k <= v_cum[g.l + 1] ORDER BY g.l LIMIT 1;
    IF v_lk BETWEEN 1 AND 3 THEN
      SELECT mod(s.x + v_world, v_world)::integer, s.y INTO v_nx, v_ny FROM public.rpg_map_road_snap(v_tx, v_ty) s;
      IF v_nx IS NOT NULL AND (v_nx <> v_tx OR v_ny <> v_ty)
         AND (SELECT h.height FROM public.rpg_map_heights(7, v_nx, v_ny, 1, 1) h) >= public.rpg_setting('map_sea_level')
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_flow(7, v_nx, v_ny, 1, 1) f WHERE f.depth >= public.rpg_setting('map_swim_depth'))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_building_cells(7, v_nx, v_ny, 1, 1))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                          WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = v_nx + 1 AND o.pos_y = v_ny + 1
                            AND public.rpg_participant_blocks(o.id)) THEN
        v_tx := v_nx; v_ty := v_ny;
      END IF;
    END IF;
  END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_y END,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  -- the swim: what drowning cost, and the points every roll paid (die x Needed / 100), all at once
  IF v_sw_rolls > 0 THEN
    v_sw_harm := ceil(v_sw_max * v_sw_harmt::numeric / v_drown)::integer;
    IF v_sw_harm > 0 THEN
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_sw_harm);
    END IF;
    IF v_sw_skill IS NOT NULL AND v_sw_points > 0 THEN
      v_sw_val := (public.rpg_sheet_values(v_p.character_id)->'values'->>v_sw_key)::numeric;
      PERFORM public.rpg_add_skill_points(v_p.character_id, v_sw_key, v_sw_points, v_sw_val);
      PERFORM public.rpg_trickle(v_p.character_id, v_sw_key, v_sw_points, '[]'::jsonb);
    END IF;
  END IF;
  -- the climbs: what the falls cost, and the points every roll paid, all at once
  IF v_cl_rolls > 0 THEN
    IF v_cl_harm > 0 THEN
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_cl_harm);
    END IF;
    IF v_cl_skill IS NOT NULL AND v_cl_points > 0 THEN
      v_sw_val := (public.rpg_sheet_values(v_p.character_id)->'values'->>v_cl_key)::numeric;
      PERFORM public.rpg_add_skill_points(v_p.character_id, v_cl_key, v_cl_points, v_sw_val);
      PERFORM public.rpg_trickle(v_p.character_id, v_cl_key, v_cl_points, '[]'::jsonb);
    END IF;
  END IF;
  -- what the character saw on the way (rpg_map_found reads these stretches)
  -- a stretch a leg of the way, as far as it was walked; and how many runs of those legs were on a road (a road is
  -- walked as a chain of legs, step 10b: one run from where the walk joins it to where it leaves)
  FOR i IN 1 .. cardinality(v_wx) - 1 LOOP
    EXIT WHEN v_cum[i] >= v_k;
    IF v_cum[i + 1] <= v_k THEN v_ex := v_wx[i + 1]; v_ey := v_wy[i + 1]; ELSE v_ex := v_tx; v_ey := v_ty; END IF;
    PERFORM public.rpg_map_trail_add(v_p.character_id, v_wx[i] + 1, v_wy[i] + 1, v_ex + 1, v_ey + 1);
    IF v_wk[i + 1] IS NOT NULL AND (i = 1 OR v_wk[i] IS NULL) THEN v_onroad := v_onroad + 1; END IF;
  END LOOP;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk)
                                   || CASE WHEN v_onroad > 0 THEN ' along the road' || CASE WHEN v_onroad > 1 THEN 's' ELSE '' END ELSE '' END || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'way' THEN ' The roads go on: the walk carries on from here next turn.' ELSE '' END
         || CASE WHEN v_why = 'shore' THEN ' The sea, water too rough to swim, or the water''s edge stops the walk.' ELSE '' END
         || CASE WHEN v_house THEN ' A house stands where the walk was heading: it stops in front of it.' ELSE '' END
         || CASE WHEN v_sw_rolls > 0 THEN ' Swims deep water: ' || v_sw_rolls || ' Swimming rolls' || CASE WHEN v_sw_gear THEN ' with gear' ELSE '' END
                                          || ' (' || trim_scale(coalesce(v_sw_skill, 0)) || ' against up to ' || trim_scale(v_sw_maxdif) || ')'
                                          || CASE WHEN v_sw_dips > 0 THEN ', under water ' || v_sw_dips || CASE WHEN v_sw_dips = 1 THEN ' time' ELSE ' times' END
                                                  || ', the longest ' || public.rpg_map_duration_text(v_sw_long) ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_sw_harmt > 0 THEN ' Out of breath under water: ' || ceil(v_sw_max * v_sw_harmt::numeric / v_drown) || ' damage.' ELSE '' END
         || CASE WHEN v_why = 'drown' THEN ' Goes down in the water.' ELSE '' END
         || CASE WHEN v_cl_count > 0 THEN ' Climbs ' || v_cl_count || CASE WHEN v_cl_count = 1 THEN ' cliff: ' ELSE ' cliffs: ' END || v_cl_rolls || CASE WHEN v_cl_rolls = 1 THEN ' Climbing roll' ELSE ' Climbing rolls' END
                                          || CASE WHEN v_cl_gear THEN ' with gear' ELSE '' END || ' (' || trim_scale(coalesce(v_cl_skill, 0)) || ' against up to ' || trim_scale(v_cl_maxdif) || ')'
                                          || CASE WHEN v_cl_falls > 0 THEN ', ' || v_cl_falls || CASE WHEN v_cl_falls = 1 THEN ' fall' ELSE ' falls' END || ': ' || v_cl_harm || ' damage' ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_why = 'fell' THEN ' Falls and is down at the foot of a cliff.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text((SELECT l.steps FROM public.rpg_map_line(v_tx, v_ty, v_gx, v_gy) l)) || ' to go.' ELSE '' END;
  IF v_why = 'meet' THEN
    PERFORM set_config('rpg.engine', 'on', true);
    v_cp := public.rpg_session_add(v_sid, NULL, v_meet);
    PERFORM public.rpg_map_set_down(v_cp, v_tx + 1, v_ty + 1, public.rpg_setting('encounter_squares')::integer);
    -- both see each other when the walk stops: each first acts one beat after that moment, as when a fight starts
    UPDATE public.rpg_session_participants
       SET next_tick = (SELECT s.clock FROM public.rpg_sessions s WHERE s.id = v_sid) + v_walk + public.rpg_action_ticks(v_cp, 1)
     WHERE id = v_cp;
    UPDATE public.rpg_sessions SET turn_move_ticks = v_walk + public.rpg_action_ticks(p_participant_id, 1) WHERE id = v_sid;
    SELECT public.rpg_square_gap(v_tx + 1, v_ty + 1, c.pos_x, c.pos_y) INTO v_gap FROM public.rpg_session_participants c WHERE c.id = v_cp;
    v_text := v_text || ' An hour in a haunt: the site rolls ' || v_rolls[cardinality(v_rolls)] || ', ' || v_chance || ' or less meets a creature. '
           || (SELECT c.name FROM public.rpg_session_participants c WHERE c.id = v_cp)
           || CASE WHEN v_gap IS NULL THEN ' is here!' ELSE ' appears ' || public.rpg_map_length_text(v_gap) || ' away!' END;
  ELSIF cardinality(v_rolls) > 0 THEN
    v_text := v_text || ' Hours in a haunt: the site rolls ' || array_to_string(v_rolls, ', ') || ' (' || v_chance || ' or less meets a creature).';
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$;

-- the rule card: roads wander
UPDATE public.rpg_rules SET body = replace(body,
'Roads join the places people live, straight from one to the next.',
'Roads join the places people live, from one to the next, and wander on the way: a road leaves each place straight and bends about the line between them, its biggest bends (up to 3.6 miles long) swinging a highway sideways by 6 in 100 of their length, a road 9 and a lane 12, and every bend half as long swinging less for its length, so a road is smoothest close up and the zoomed-in road lies where the zoomed-out one was drawn. The houses of a village, town or city line the road where it truly runs.
*A lane between villages 1.8 miles apart swings about 200 m either way; a highway between towns 7 miles apart about 350 m, 600 m at most.*'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('and wander on the way' IN body) = 0;

