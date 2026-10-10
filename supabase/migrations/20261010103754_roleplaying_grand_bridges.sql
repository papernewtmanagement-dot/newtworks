-- Grand bridges (Peter 2026-10-09: a road can go over deep water on a grand bridge, and bridges are as straight as possible).

CREATE OR REPLACE FUNCTION public.rpg_map_wet_at(p_x double precision, p_y double precision)
 RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Whether a point of the world (squares from 0) lies on the sea, a great lake or a lake (grand bridges, Peter 2026-10-09:
-- a road can go over deep water on a grand bridge, and a bridge runs straight), read on the Country grid from the saved
-- map (rpg_map_cache level 3: every Country grid next to big water is saved ahead, speed step 3), else from the
-- Continent cell (level 2, saved), else worked out (rpg_map_cells). The one home of that test: rpg_map_road_lines (a
-- stretch over water runs straight) and rpg_map_roads (a highway steps over a town site on water) read it.
DECLARE v_cx bigint; v_cy bigint; v_k text; v_g bigint;
BEGIN
  v_cx := mod(mod(floor(p_x / 20736)::bigint, 1728) + 1728, 1728);
  v_cy := floor(p_y / 20736)::bigint;
  IF v_cy < 0 OR v_cy >= 864 THEN RETURN true; END IF;
  SELECT m.kinds[(v_cy % 12) * 12 + (v_cx % 12) + 1] INTO v_k FROM public.rpg_map_cache m WHERE m.level = 3 AND m.gx = v_cx / 12 AND m.gy = v_cy / 12;
  IF v_k IS NULL THEN
    v_cx := v_cx / 12; v_cy := v_cy / 12;
    SELECT m.kinds[(v_cy % 12) * 12 + (v_cx % 12) + 1] INTO v_k FROM public.rpg_map_cache m WHERE m.level = 2 AND m.gx = v_cx / 12 AND m.gy = v_cy / 12;
    IF v_k IS NULL THEN SELECT c.kind INTO v_k FROM public.rpg_map_cells(2, v_cx::integer, v_cy::integer, 1, 1) c; END IF;
  END IF;
  RETURN coalesce(v_k IN ('sea', 'deep', 'water'), false);
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_map_wet_at(double precision, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_wet_at(double precision, double precision) TO service_role;
CREATE OR REPLACE FUNCTION public.rpg_map_road_lines(p_class integer[], p_ax double precision[], p_ay double precision[], p_bx double precision[], p_by double precision[], p_a text[], p_b text[], p_cell double precision, p_s double precision[] DEFAULT NULL::double precision[], p_x0 double precision DEFAULT NULL::double precision, p_y0 double precision DEFAULT NULL::double precision, p_x1 double precision DEFAULT NULL::double precision, p_y1 double precision DEFAULT NULL::double precision, p_per integer DEFAULT 6)
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
-- leaves each end straight along the line. (Grand bridges, Peter 2026-10-09: roads may cross deep water on a grand
-- bridge, and a bridge is as straight as can be) A stretch whose line crosses the sea or a lake does not wander.
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
                   n0.n0, l.len / n0.n0 AS gap0, CASE WHEN wt.wet THEN 0 ELSE cw.share END AS share, greatest(coalesce(2 * p_cell, 0), cfg.wave * cw.width) AS fine,
                   CASE WHEN l.len > 0 AND l.len / n0.n0 >= cfg.wave * cw.width THEN floor(ln(l.len / n0.n0 / (cfg.wave * cw.width)) / ln(2.0))::integer + 1 ELSE 0 END AS kall
              FROM unnest(p_class, p_ax, p_ay, p_bx, p_by, p_a, p_b) WITH ORDINALITY AS q(class, ax, ay, bx, by, a, b, i)
              JOIN cw ON cw.class = q.class CROSS JOIN cfg
             CROSS JOIN LATERAL (SELECT sqrt(power(q.bx - q.ax, 2) + power(q.by - q.ay, 2)) AS len) l
             CROSS JOIN LATERAL (SELECT greatest(2, ceil(l.len / cfg.bend))::integer AS n0) n0
             -- (grand bridges) a stretch whose straight line crosses the sea or a lake (rpg_map_wet_at, a point every Country
             -- cell along it) runs straight from end to end: a grand bridge does not wander
             CROSS JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM generate_series(1, ceil(l.len / 20736.0)::integer) AS g(j)
                                                 WHERE public.rpg_map_wet_at(q.ax + (q.bx - q.ax) * g.j / (ceil(l.len / 20736.0) + 1),
                                                                             q.ay + (q.by - q.ay) * g.j / (ceil(l.len / 20736.0) + 1))) AS wet) wt),
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
$function$
;
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
-- (id: great_city, city, town or village, as rpg_map_towns reads them, a great city a city to the roads; a site inside it that is not named has no one) when the
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
  v_key text; v_cache jsonb; v_rows jsonb; v_c6 integer; v_skey text;
BEGIN
  IF p_level < 3 OR coalesce(p_what, 0) = 0 THEN RETURN; END IF;
  -- (speed step 2, 2026-10-09) the Country, Region, City and District grids keep the stretches a read worked out on the
  -- saved map row of the grid the block starts in (notes: roads, by what was asked), so the next read of the same block
  -- finds them there; a read lists what it worked out in rpg.rd_new and rpg_map_road_save keeps it
  IF p_level BETWEEN 3 AND 6 AND p_x0 >= 0 AND p_y0 >= 0 THEN
    v_skey := p_level || ':' || p_x0 || ':' || p_y0 || ':' || p_cols || ':' || p_rows || ':' || p_what || ':' || coalesce(p_pad, 0);
    SELECT m.notes -> 'roads' -> v_skey INTO v_rows FROM public.rpg_map_cache m WHERE m.level = p_level AND m.gx = p_x0 / 12 AND m.gy = p_y0 / 12;
    IF v_rows IS NOT NULL THEN
      RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::double precision, (e.v ->> 2)::double precision, (e.v ->> 3)::double precision, (e.v ->> 4)::double precision, e.v ->> 5, e.v ->> 6
                     FROM jsonb_array_elements(v_rows) AS e(v);
      RETURN;
    END IF;
  END IF;
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
         st0 AS MATERIALIZED (
           SELECT pr.pvx, pr.pvy, pr.qvx, pr.qvy, i,
                  pr.ptx + floor((2::numeric * i * (pr.qtx - pr.ptx) + nn.n) / (2 * nn.n))::bigint AS sx,
                  pr.pty + floor((2::numeric * i * (pr.qty - pr.pty) + nn.n) / (2 * nn.n))::bigint AS sy
             FROM pr CROSS JOIN LATERAL (SELECT greatest(abs(pr.qtx - pr.ptx), abs(pr.qty - pr.pty)) AS n) nn
            CROSS JOIN LATERAL generate_series(0, nn.n) AS i),
         -- (grand bridges, Peter 2026-10-09) a step whose town site stands on the sea or a lake (rpg_map_wet_at) is passed
         -- over: the highway runs straight from the last site on land to the next, on one grand bridge
         st AS MATERIALIZED (
           SELECT q.pvx, q.pvy, q.qvx, q.qvy, (row_number() OVER (PARTITION BY q.pvx, q.pvy, q.qvx, q.qvy ORDER BY q.i) - 1)::integer AS i, q.sx, q.sy
             FROM (SELECT st0.*, max(st0.i) OVER (PARTITION BY st0.pvx, st0.pvy, st0.qvx, st0.qvy) AS imax FROM st0) q
            CROSS JOIN LATERAL public.rpg_map_hub(q.sx, q.sy, c.seed, c.nv, c.at) h
            CROSS JOIN LATERAL public.rpg_map_site(h.vx, h.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
            WHERE q.i = 0 OR q.i = q.imax OR NOT public.rpg_map_wet_at(x.x::double precision, x.y::double precision)),
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
                             ELSE replace(coalesce(p_towns ->> ('site-' || x.vw || '-' || cu.vy), 'no'), 'great_city', 'city') END)
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
                        CASE WHEN cr.none THEN 'no' WHEN p_towns ->> ('site-' || cr.vw || '-' || cr.vy) IN ('town', 'city', 'great_city') THEN 'town' ELSE 'no' END)
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
  IF v_skey IS NOT NULL THEN
    PERFORM set_config('rpg.rd_new', (coalesce(nullif(current_setting('rpg.rd_new', true), ''), '{}')::jsonb || jsonb_build_object(v_skey, coalesce(v_rows, '[]'::jsonb)))::text, true);
  END IF;
  RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::double precision, (e.v ->> 2)::double precision, (e.v ->> 3)::double precision, (e.v ->> 4)::double precision, e.v ->> 5, e.v ->> 6
                 FROM jsonb_array_elements(v_rows) AS e(v);
END;
$function$
;

-- the saved roads, and the houses and streets laid along them, are read again with the bridges
UPDATE public.rpg_map_cache m SET notes = m.notes - 'roads' - 'houses' - 'streets' WHERE m.notes ?| ARRAY['roads', 'houses', 'streets'];

