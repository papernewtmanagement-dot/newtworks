-- Roleplaying world map step 3, follow-up (2026-10-08): live battle grids read slower than before map40 (a slid battle grid
-- saves the two grids under it, and each worked out the buildings again to keep streets out of churchyards). A church now
-- stands across a street or a lane and its walls end it, with no churchyard cut, so the street squares need no buildings;
-- the market place, streets and lanes keep a point every 4 squares (they are straight, or a lane nearly so) instead of
-- every half square, so each building checks far fewer pieces of line. The saved map is cleared (the streets move a
-- hair, so the District grids' saved buildings and streets are made again).

-- (step 3, streets) The streets of every village, town and city: the one home of where they run and of each
-- settlement's plot width. Moved out of rpg_map_buildings (its roads part unchanged) and grown with the market place,
-- the streets and lanes behind the main road, and the cathedral close.
CREATE OR REPLACE FUNCTION public.rpg_map_town_streets(p_tw jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- For each settlement in p_tw (as rpg_map_town_grounds lists them), its streets and plot width, worked out once a
-- transaction and kept in the setting rpg.townstreets (by settlement id); returns the entries of those asked for.
-- An entry: f (the plot width, in squares), people, plots (how many plots both sides of its streets hold), main (the
-- line whose first plot on the left is the main plot, where the main church stands), close (a great city's cathedral:
-- j the try it stands at, x, y its middle; or null) and lines, each a street plots line: k (its order), class (1
-- highway, 2 road, 3 lane between places; 4 the market place, 5 a street, 6 a lane inside the town), ax, ay, bx, by
-- (its ends), a, b (their ids, which key its bends), len, t0 (how far along it passes nearest the middle), half (half
-- its width), lo, hi (how far along it houses may stand) and pts (its points: n, s along the straight line, x, y).
--
-- The roads (as before, step 8c): every road whose line may cross the settlement, each where it comes near (24 points
-- to its finest bend), lined with plots from where it passes nearest the middle; a middle only one road reaches lets
-- that road run on through to the far side.
--
-- Inside a town, city or great city (Peter 2026-10-07 21:05: battle grids in a city should look like fighting in the
-- streets; a city of 10,000 had about 7 street lines and room for 1,300 plots for its 2,400 households):
--   the market place: the main road (its first, the biggest) widened at the middle, map_street_market_len_<kind>_* long
--     and map_street_market_wide_<kind>_* across (rolled at the middle square, part 12, layers 1281 and 1282), lined
--     with plots like a street; its first plot on the left is the main plot (Slater 1987, Britnell 1996: the market
--     place was a widened street at the heart of the town, its church on it);
--   streets behind the main road, parallel to it, and lanes across them (Conzen 1960, Slater 1981: plot series with
--     back lanes behind them; Lilley 2009, Beresford 1967: planned towns laid on a grid). As much street as the
--     households need frontage for: households (people over map_house_people) times the middle plot width of its kind,
--     over two (a plot each side), less the roads and the market place already there; the streets that much apart
--     on average over the ground the town covers (its area, from its edge at 72 angles) with the lanes c times as far
--     apart (c rolled from map_street_cross_*, layer 1283), so the average gap G = area x (1 + 1/c) / length needed,
--     held inside map_street_gap_low to _high. Built closest at the middle and loosest at the edge (Conzen 1960: the
--     plots near the market filled in first; the burgage cycle): the gap at a distance d from the main road is
--     map_street_gap_low + 2 (G - low) d / R (R = how far the ground reaches), never past _high, so on average it is
--     G again; the lanes the same, c times as far apart. A settlement whose roads and market already give its
--     households their frontage gets none. Each street and lane runs as far as the ground does (to map_street_edge_m inside its edge), in
--     pieces where the edge cuts it, none shorter than map_street_min_m. Streets run straight; lanes wander a little
--     (map_road_6_wander).
--   a great city's cathedral (step 14e) stands in its own close: tried as before (the three widest gaps between the
--     roads that leave the middle, then the eight points of the compass, at map_house_cathedral_close_tries distances,
--     the nearest clear of the roads and the market place and with no water in the District cells under it), now once
--     a settlement here rather than for every block; the streets and lanes keep out of its close (its reach and
--     map_street_close_m more, and how far a lane may wander).
-- Villages keep their one street (the lane through them).
#variable_conflict use_column
DECLARE
  v_tl   jsonb;
  v_out  jsonb := '{}';
  v_new  jsonb;
  v_j    jsonb;
  g      record;
  t      record;
  v_roads jsonb;
  v_lines jsonb;
  v_len  double precision;
  v_people double precision;
  v_px double precision; v_py double precision; v_ux double precision; v_uy double precision;
  v_mlen double precision; v_mwide double precision;
  v_area double precision; v_need double precision; v_gap double precision; v_c double precision;
  v_reach double precision;
  v_close jsonb;
  v_main integer;
  v_extra jsonb;
  v_grid jsonb;
  v_offs double precision[];
  v_coffs double precision[];
  v_o double precision;
  v_k double precision;
BEGIN
  v_tl := coalesce(nullif(current_setting('rpg.townstreets', true), ''), '{}')::jsonb;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_tw) e WHERE NOT v_tl ? (e ->> 'town')) THEN
    RETURN (SELECT coalesce(jsonb_object_agg(e ->> 'town', v_tl -> (e ->> 'town')), '{}') FROM jsonb_array_elements(p_tw) e);
  END IF;
  v_j := (SELECT jsonb_object_agg(s.key, s.value) FROM public.rpg_settings s
           WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
             AND (s.key LIKE 'map\_house\_%' OR s.key LIKE 'map\_street\_%' OR s.key LIKE 'map\_road\__\_width' OR s.key LIKE 'map\_road\__\_wander'
                  OR s.key IN ('map_square_m', 'map_seed')));
  SELECT (v_j ->> 'map_square_m')::double precision AS sq, (v_j ->> 'map_seed')::integer AS seed,
         (v_j ->> 'map_house_perch_m')::double precision AS perch, (v_j ->> 'map_house_people')::double precision AS household,
         (v_j ->> 'map_road_1_width')::double precision AS w1, (v_j ->> 'map_road_2_width')::double precision AS w2,
         (v_j ->> 'map_road_3_width')::double precision AS w3, (v_j ->> 'map_road_5_width')::double precision AS w5,
         (v_j ->> 'map_road_6_width')::double precision AS w6, (v_j ->> 'map_road_6_wander')::double precision AS wander6,
         (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 6)::double precision AS dc
    INTO g;

  FOR t IN SELECT * FROM jsonb_to_recordset(p_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision, shape double precision[],
                                                     card uuid, people integer, cw double precision, ch double precision, fx double precision, fy double precision) LOOP
    CONTINUE WHEN v_tl ? t.town OR v_out ? t.town;
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
         -- how much road runs through it: every line, measured four squares at a time where it lies on the
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
                       ELSE power((p.x - t.mx) / t.cw, 2) + power((p.y - t.my) / t.ch, 2) <= 1 END)
    SELECT (SELECT sl.len FROM sl),
           coalesce((SELECT jsonb_agg(jsonb_build_object('k', lr.k, 'class', lr.class, 'ax', lr.ax, 'ay', lr.ay, 'bx', lr.bx, 'by', lr.by,
                                                         'a', lr.a, 'b', lr.b, 'len', lr.len, 't0', lr.t0, 'half', lr.half, 'lo', lr.lo, 'hi', lr.hi,
                                                         'pts', (SELECT jsonb_agg(jsonb_build_array(lp.n, round(lp.s::numeric, 2), round(lp.x::numeric, 2), round(lp.y::numeric, 2)) ORDER BY lp.n)
                                                                   FROM lp WHERE lp.k = lr.k)) ORDER BY lr.k)
                       FROM lr), '[]'::jsonb)
      INTO v_len, v_roads;
    -- its people: a rolled settlement's own count; a card's ground at its kind's crowding (map_<kind>_density)
    v_people := coalesce(t.people::double precision,
                         pi() * t.cw * t.ch * g.sq * g.sq / 10000 * (SELECT s.value FROM public.rpg_settings s
                                                                       WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_' || t.kind || '_density'));
    v_lines := v_roads;
    v_main := CASE WHEN jsonb_array_length(v_roads) > 0 THEN 1 END;
    v_close := NULL;
    v_len := coalesce(v_len, 0);

    IF t.kind IN ('town', 'city', 'great_city') AND jsonb_array_length(v_roads) > 0 THEN
      -- where the main road (its first) passes nearest the middle, and the way it runs there
      SELECT q.x, q.y, q.ux, q.uy INTO v_px, v_py, v_ux, v_uy
        FROM (SELECT p.x, p.y, nx.x - pv.x AS dx, nx.y - pv.y AS dy
                FROM jsonb_array_elements(v_roads -> 0 -> 'pts') WITH ORDINALITY AS e(v, o)
               CROSS JOIN LATERAL (SELECT (e.v ->> 2)::double precision AS x, (e.v ->> 3)::double precision AS y) p
               CROSS JOIN LATERAL (SELECT (coalesce(v_roads -> 0 -> 'pts' -> (e.o::integer), e.v) ->> 2)::double precision AS x,
                                          (coalesce(v_roads -> 0 -> 'pts' -> (e.o::integer), e.v) ->> 3)::double precision AS y) nx
               CROSS JOIN LATERAL (SELECT (coalesce(v_roads -> 0 -> 'pts' -> greatest(e.o::integer - 2, 0), e.v) ->> 2)::double precision AS x,
                                          (coalesce(v_roads -> 0 -> 'pts' -> greatest(e.o::integer - 2, 0), e.v) ->> 3)::double precision AS y) pv
               ORDER BY power(p.x - t.mx, 2) + power(p.y - t.my, 2) LIMIT 1) z
       CROSS JOIN LATERAL (SELECT z.x, z.y, z.dx / nullif(sqrt(z.dx * z.dx + z.dy * z.dy), 0) AS ux, z.dy / nullif(sqrt(z.dx * z.dx + z.dy * z.dy), 0) AS uy) q;
      IF v_ux IS NULL THEN
        v_ux := ((v_roads -> 0 ->> 'bx')::double precision - (v_roads -> 0 ->> 'ax')::double precision) / (v_roads -> 0 ->> 'len')::double precision;
        v_uy := ((v_roads -> 0 ->> 'by')::double precision - (v_roads -> 0 ->> 'ay')::double precision) / (v_roads -> 0 ->> 'len')::double precision;
      END IF;
      -- the market place, rolled at the middle square
      v_mlen := ((v_j ->> ('map_street_market_len_' || t.kind || '_low'))::double precision
                 + ((v_j ->> ('map_street_market_len_' || t.kind || '_high'))::double precision - (v_j ->> ('map_street_market_len_' || t.kind || '_low'))::double precision)
                   * (public.rpg_map_roll(g.seed, 1281, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0) / g.sq;
      v_mwide := ((v_j ->> ('map_street_market_wide_' || t.kind || '_low'))::double precision
                  + ((v_j ->> ('map_street_market_wide_' || t.kind || '_high'))::double precision - (v_j ->> ('map_street_market_wide_' || t.kind || '_low'))::double precision)
                    * (public.rpg_map_roll(g.seed, 1282, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0) / g.sq;
      v_extra := jsonb_build_array(jsonb_build_object('k', 50, 'class', 4, 'ax', v_px - v_ux * v_mlen / 2, 'ay', v_py - v_uy * v_mlen / 2,
                                                      'bx', v_px + v_ux * v_mlen / 2, 'by', v_py + v_uy * v_mlen / 2,
                                                      'a', t.town || ':m:a', 'b', t.town || ':m:b', 'half', v_mwide / 2));
      v_main := 50;

      -- a great city's cathedral close: the nearest try clear of the roads and the market place, with no water under it
      IF t.kind = 'great_city' THEN
        WITH lr AS (SELECT (l ->> 'k')::integer AS k, (l ->> 'class')::integer AS class, (l ->> 'ax')::double precision AS ax, (l ->> 'ay')::double precision AS ay,
                           (l ->> 'bx')::double precision AS bx, (l ->> 'by')::double precision AS by, (l ->> 'len')::double precision AS len,
                           (l ->> 't0')::double precision AS t0, (l ->> 'half')::double precision AS half, l -> 'pts' AS pts
                      FROM jsonb_array_elements(v_roads) l),
             -- the pieces of the roads, and the market place as one piece
             sg AS (SELECT q.half, q.x0, q.y0, q.x1, q.y1
                      FROM (SELECT lr.half, (e.v ->> 2)::double precision AS x0, (e.v ->> 3)::double precision AS y0,
                                   lead((e.v ->> 2)::double precision) OVER w AS x1, lead((e.v ->> 3)::double precision) OVER w AS y1,
                                   (e.v ->> 0)::integer AS n, lead((e.v ->> 0)::integer) OVER w AS n1
                              FROM lr CROSS JOIN LATERAL jsonb_array_elements(lr.pts) AS e(v)
                            WINDOW w AS (PARTITION BY lr.k ORDER BY (e.v ->> 0)::integer)) q
                     WHERE q.n1 = q.n + 1
                    UNION ALL
                    SELECT v_mwide / 2, v_px - v_ux * v_mlen / 2, v_py - v_uy * v_mlen / 2, v_px + v_ux * v_mlen / 2, v_py + v_uy * v_mlen / 2),
             ka AS (
               SELECT atan2(d.s * (lr.by - lr.ay), d.s * (lr.bx - lr.ax)) AS th
                 FROM lr CROSS JOIN (VALUES (1), (-1)) AS d(s)
                WHERE (d.s = 1 AND lr.t0 < lr.len - 1) OR (d.s = -1 AND lr.t0 > 1)),
             kg AS (
               SELECT r.th, r.gr
                 FROM (SELECT q.th + q.gap / 2 AS th, row_number() OVER (ORDER BY q.gap DESC, q.th) AS gr
                         FROM (SELECT ka.th, coalesce(lead(ka.th) OVER w, first_value(ka.th) OVER w + 2 * pi()) - ka.th AS gap
                                 FROM ka WINDOW w AS (ORDER BY ka.th)) q) r
                WHERE r.gr <= 3
               UNION ALL
               SELECT c.n * pi() / 4, 3 + c.n + 1 FROM generate_series(0, 7) AS c(n) WHERE EXISTS (SELECT 1 FROM ka)),
             kr AS (
               SELECT kg.th, kg.gr,
                      (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + n, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0 ORDER BY n)
                         FROM generate_series(1, 9) AS n) AS u,
                      (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + n, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0 ORDER BY n)
                         FROM generate_series(1, 12) AS n) AS v
                 FROM kg),
             kc AS (
               SELECT kr.*, (tn.n - 1) * 11 + kr.gr AS j, ((1 + 0.2 * (tn.n - 1)) * e.reach) / g.sq AS d, e.reach
                 FROM kr
                CROSS JOIN LATERAL (SELECT max(sqrt(power(abs(z.ex) + z.len / 2, 2) + power(abs(z.ey) + z.wide / 2, 2))) AS reach
                                      FROM public.rpg_map_church_plan('cathedral', t.kind, kr.u::double precision[], kr.v::double precision[], v_j) z) e
                CROSS JOIN LATERAL generate_series(1, (v_j ->> 'map_house_cathedral_close_tries')::integer) AS tn(n)),
             -- its parts in squares at each try (as rpg_map_buildings lays a cathedral: ex east, ey south of its middle)
             kp AS (
               SELECT kc.j, kc.d, kc.th, kc.reach, t.mx + kc.d * cos(kc.th) + c.ex / g.sq AS cx, t.my + kc.d * sin(kc.th) + c.ey / g.sq AS cy,
                      CASE WHEN c.ridge_ew THEN 1 ELSE 0 END AS rx, CASE WHEN c.ridge_ew THEN 0 ELSE 1 END AS ry,
                      c.len / 2 / g.sq AS hl, c.wide / 2 / g.sq AS hw
                 FROM kc CROSS JOIN LATERAL public.rpg_map_church_plan('cathedral', t.kind, kc.u::double precision[], kc.v::double precision[], v_j) c),
             kl AS (
               SELECT kp.j, bool_and(NOT EXISTS (
                        SELECT 1 FROM sg
                         CROSS JOIN LATERAL (SELECT sg.half - 0.01 AS wide) w
                         CROSS JOIN LATERAL (SELECT sg.x0 - kp.cx AS x0, sg.y0 - kp.cy AS y0, sg.x1 - kp.cx AS x1, sg.y1 - kp.cy AS y1) e
                         WHERE least(sg.x0, sg.x1) <= kp.cx + kp.hl + w.wide AND greatest(sg.x0, sg.x1) >= kp.cx - kp.hl - w.wide
                           AND least(sg.y0, sg.y1) <= kp.cy + kp.hl + w.wide AND greatest(sg.y0, sg.y1) >= kp.cy - kp.hl - w.wide
                           AND public.rpg_seg_box(e.x0 * kp.rx + e.y0 * kp.ry, e.y0 * kp.rx - e.x0 * kp.ry, e.x1 * kp.rx + e.y1 * kp.ry, e.y1 * kp.rx - e.x1 * kp.ry,
                                                  -(kp.hl + w.wide), -(kp.hw + w.wide), kp.hl + w.wide, kp.hw + w.wide))) AS clear
                 FROM kp GROUP BY kp.j),
             -- the District cells under the corners and middles of the parts of the clear tries
             kq AS MATERIALIZED (
               SELECT kp.j, floor((q.a * kp.hl * kp.rx - q.b * kp.hw * kp.ry + kp.cx) / g.dc)::integer AS dx,
                      floor((q.a * kp.hl * kp.ry + q.b * kp.hw * kp.rx + kp.cy) / g.dc)::integer AS dy
                 FROM kp JOIN kl ON kl.j = kp.j AND kl.clear
                CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             kb AS (SELECT min(kq.dx) AS x0, min(kq.dy) AS y0, max(kq.dx) - min(kq.dx) + 1 AS cols, max(kq.dy) - min(kq.dy) + 1 AS rows FROM kq HAVING count(*) > 0),
             kw AS MATERIALIZED (SELECT f.x, f.y FROM kb CROSS JOIN LATERAL public.rpg_map_flow(6, kb.x0, kb.y0, kb.cols, kb.rows) f WHERE f.depth > 0 OR f.line > 0),
             kd AS (SELECT kl.j FROM kl WHERE kl.clear AND NOT EXISTS (SELECT 1 FROM kq JOIN kw ON kw.x = kq.dx AND kw.y = kq.dy WHERE kq.j = kl.j))
        SELECT jsonb_build_object('j', kc.j, 'x', t.mx + kc.d * cos(kc.th), 'y', t.my + kc.d * sin(kc.th), 'reach', kc.reach / g.sq)
          INTO v_close
          FROM kc WHERE kc.j = (SELECT min(kd.j) FROM kd) LIMIT 1;
      END IF;

      -- the streets behind the main road and the lanes across them, as much as the households need
      SELECT 0.5 * sum(power(public.rpg_map_town_edge(2 * pi() * i / 72, t.r, t.shape), 2)) * 2 * pi() / 72 INTO v_area
        FROM generate_series(0, 71) AS i WHERE t.card IS NULL;
      v_area := coalesce(v_area, pi() * t.cw * t.ch);
      v_need := v_people / g.household
                * ((v_j ->> ('map_house_plot_' || t.kind || '_low'))::double precision + (v_j ->> ('map_house_plot_' || t.kind || '_high'))::double precision) / 2
                * g.perch / g.sq / 2
                - v_len - v_mlen;
      IF v_need > 0 THEN
        v_c := (v_j ->> 'map_street_cross_low')::double precision
               + ((v_j ->> 'map_street_cross_high')::double precision - (v_j ->> 'map_street_cross_low')::double precision)
                 * (public.rpg_map_roll(g.seed, 1283, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0;
        v_gap := least(greatest(v_area * (1 + 1 / v_c) / v_need, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                       (v_j ->> 'map_street_gap_high')::double precision / g.sq);
        v_reach := greatest(t.fx, t.fy);
        -- where the streets lie each side of the main road, and the lanes each side of the middle
        v_k := 2 * (v_gap - (v_j ->> 'map_street_gap_low')::double precision / g.sq) / v_reach;
        v_offs := '{}'; v_o := 0;
        LOOP
          v_o := v_o + least(greatest((v_j ->> 'map_street_gap_low')::double precision / g.sq + v_k * v_o, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                             (v_j ->> 'map_street_gap_high')::double precision / g.sq);
          EXIT WHEN v_o > v_reach;
          v_offs := v_offs || v_o;
        END LOOP;
        v_coffs := '{}'; v_o := 0;
        LOOP
          v_o := v_o + v_c * least(greatest((v_j ->> 'map_street_gap_low')::double precision / g.sq + v_k * v_o / v_c, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                                   (v_j ->> 'map_street_gap_high')::double precision / g.sq) / CASE WHEN cardinality(v_coffs) = 0 THEN 2 ELSE 1 END;
          EXIT WHEN v_o > v_reach;
          v_coffs := v_coffs || v_o;
        END LOOP;
        -- each street (o = how far to one side of the main road, along it) and lane (across it, its own way), sampled
        -- every two squares along its length: on the ground (a hair inside its edge) and outside the cathedral close;
        -- each unbroken run of such samples a piece, at least map_street_min_m long
        WITH ln AS (
               SELECT 5 AS class, d.s * n AS o, v_px + (-v_uy) * d.s * v_offs[n] AS bx, v_py + v_ux * d.s * v_offs[n] AS by, v_ux AS ux, v_uy AS uy, 'p' || d.s * n AS tag
                 FROM generate_series(1, cardinality(v_offs)) AS n CROSS JOIN (VALUES (1), (-1)) AS d(s)
               UNION ALL
               SELECT 6, d.s * n, v_px + v_ux * d.s * v_coffs[n], v_py + v_uy * d.s * v_coffs[n], -v_uy, v_ux, 'c' || d.s * n
                 FROM generate_series(1, cardinality(v_coffs)) AS n CROSS JOIN (VALUES (1), (-1)) AS d(s)),
             sm AS (
               SELECT ln.*, s, ln.bx + ln.ux * s AS x, ln.by + ln.uy * s AS y
                 FROM ln CROSS JOIN LATERAL generate_series(-ceil(v_reach / 2)::integer * 2, ceil(v_reach / 2)::integer * 2, 2) AS s),
             si AS (
               SELECT sm.*,
                      CASE WHEN t.card IS NULL
                           THEN sqrt(power(sm.x - t.mx, 2) + power(sm.y - t.my, 2))
                                <= public.rpg_map_town_edge(atan2(sm.y - t.my, sm.x - t.mx), t.r, t.shape) - (v_j ->> 'map_street_edge_m')::double precision / g.sq
                           ELSE power((sm.x - t.mx) / t.cw, 2) + power((sm.y - t.my) / t.ch, 2) <= 1 END
                      AND (v_close IS NULL
                           OR sqrt(power(sm.x - (v_close ->> 'x')::double precision, 2) + power(sm.y - (v_close ->> 'y')::double precision, 2))
                              > (v_close ->> 'reach')::double precision + (v_j ->> 'map_street_close_m')::double precision / g.sq
                                + CASE WHEN sm.class = 6 THEN g.wander6 * v_reach ELSE 0 END + 2) AS ok
                 FROM sm),
             rn AS (SELECT si.*, si.s / 2 - row_number() OVER (PARTITION BY si.class, si.o ORDER BY si.s) AS run FROM si WHERE si.ok),
             pc AS (SELECT rn.class, rn.o, rn.tag, rn.run, rn.ux, rn.uy, min(rn.s) AS s0, max(rn.s) AS s1
                      FROM rn GROUP BY rn.class, rn.o, rn.tag, rn.run, rn.ux, rn.uy
                     HAVING max(rn.s) - min(rn.s) >= (v_j ->> 'map_street_min_m')::double precision / g.sq),
             pe AS (SELECT pc.*, l.bx + l.ux * pc.s0 AS ax, l.by + l.uy * pc.s0 AS ay, l.bx + l.ux * pc.s1 AS ex, l.by + l.uy * pc.s1 AS ey,
                           row_number() OVER (ORDER BY pc.class, abs(pc.o), pc.o, pc.s0) AS i
                      FROM pc JOIN ln l ON l.class = pc.class AND l.o = pc.o)
        SELECT coalesce(jsonb_agg(jsonb_build_object('k', 100 + pe.i, 'class', pe.class, 'ax', pe.ax, 'ay', pe.ay, 'bx', pe.ex, 'by', pe.ey,
                                                     'a', t.town || ':' || pe.tag || ':' || pe.run || ':a', 'b', t.town || ':' || pe.tag || ':' || pe.run || ':b',
                                                     'half', CASE pe.class WHEN 5 THEN g.w5 ELSE g.w6 END / 2) ORDER BY pe.i), '[]'::jsonb)
          INTO v_grid
          FROM pe;
        v_extra := v_extra || v_grid;
      END IF;

      -- the points of the market place, the streets and the lanes, as the roads have theirs (rpg_map_road_lines, 24 points
      -- to the finest bend), where each passes nearest the middle, and its plots from end to end
      WITH ex AS (SELECT (l ->> 'k')::integer AS k, (l ->> 'class')::integer AS class, (l ->> 'ax')::double precision AS ax, (l ->> 'ay')::double precision AS ay,
                         (l ->> 'bx')::double precision AS bx, (l ->> 'by')::double precision AS by, l ->> 'a' AS a, l ->> 'b' AS b,
                         (l ->> 'half')::double precision AS half, o
                    FROM jsonb_array_elements(v_extra) WITH ORDINALITY AS e(l, o)),
           ea AS (SELECT array_agg(ex.class ORDER BY ex.o) AS class, array_agg(ex.ax ORDER BY ex.o) AS ax, array_agg(ex.ay ORDER BY ex.o) AS ay,
                         array_agg(ex.bx ORDER BY ex.o) AS bx, array_agg(ex.by ORDER BY ex.o) AS by, array_agg(ex.a ORDER BY ex.o) AS a, array_agg(ex.b ORDER BY ex.o) AS b
                    FROM ex),
           ep AS MATERIALIZED (SELECT p.i, p.n, p.s, p.x, p.y FROM ea CROSS JOIN LATERAL public.rpg_map_road_lines(ea.class, ea.ax, ea.ay, ea.bx, ea.by, ea.a, ea.b, 8, NULL, NULL, NULL, NULL, NULL, 4) p)
      SELECT v_roads || coalesce(jsonb_agg(jsonb_build_object('k', ex.k, 'class', ex.class, 'ax', ex.ax, 'ay', ex.ay, 'bx', ex.bx, 'by', ex.by,
                                                              'a', ex.a, 'b', ex.b, 'len', l0.len,
                                                              't0', (SELECT ep.s FROM ep WHERE ep.i = ex.o ORDER BY power(ep.x - t.mx, 2) + power(ep.y - t.my, 2) LIMIT 1),
                                                              'half', ex.half, 'lo', 0, 'hi', l0.len,
                                                              'pts', (SELECT jsonb_agg(jsonb_build_array(ep.n, round(ep.s::numeric, 2), round(ep.x::numeric, 2), round(ep.y::numeric, 2)) ORDER BY ep.n)
                                                                        FROM ep WHERE ep.i = ex.o)) ORDER BY ex.o), '[]'::jsonb),
             coalesce(sum(l0.len), 0)
        INTO v_lines, v_mlen
        FROM ex CROSS JOIN LATERAL (SELECT sqrt(power(ex.bx - ex.ax, 2) + power(ex.by - ex.ay, 2)) AS len) l0
       WHERE l0.len > 0;
      -- the market place, streets and lanes lie on the ground end to end: all their length counts
      v_len := v_len + v_mlen;
    END IF;

    -- the plot width, in squares: both sides of the streets shared out among the households, inside its kind's range
    v_new := jsonb_build_object(
      'f', CASE WHEN jsonb_array_length(v_lines) > 0 THEN
             least(greatest(2 * v_len * g.sq / nullif(v_people / g.household, 0),
                            (v_j ->> ('map_house_plot_' || t.kind || '_low'))::double precision * g.perch),
                   (v_j ->> ('map_house_plot_' || t.kind || '_high'))::double precision * g.perch) / g.sq END,
      'people', v_people, 'main', v_main, 'close', v_close, 'lines', v_lines);
    v_new := v_new || jsonb_build_object('plots', 2 * v_len / nullif((v_new ->> 'f')::double precision, 0));
    v_out := v_out || jsonb_build_object(t.town, v_new);
  END LOOP;
  v_tl := v_tl || v_out;
  PERFORM set_config('rpg.townstreets', v_tl::text, true);
  RETURN (SELECT coalesce(jsonb_object_agg(e ->> 'town', v_tl -> (e ->> 'town')), '{}') FROM jsonb_array_elements(p_tw) e);
END;
$function$;

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
--   city: the same with two or three storeys; great city (step 12a): three or four.
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
-- settlement's streets and plot width (rpg.townstreets, by settlement, kept by rpg_map_town_streets: step 3 its roads, market
-- place, streets and lanes), whether each house stands on its own dry
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
  v_j jsonb;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.houses', true), ''), '{}')::jsonb;
  v_c := v_all -> v_key;
  IF v_c IS NULL THEN
    -- the numbers, read once; r = how far a house reaches from its middle at most, in squares (half the diagonal of
    -- the biggest house, and one more)
    v_j := (SELECT jsonb_object_agg(s.key, s.value) FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key LIKE 'map\_house\_%');
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
                  max(st.v) FILTER (WHERE st.key IN ('map_house_plot_town_high', 'map_house_plot_city_high', 'map_house_plot_great_city_high')) AS plot_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_road_1_width') AS w1, max(st.v) FILTER (WHERE st.key = 'map_road_2_width') AS w2,
                  max(st.v) FILTER (WHERE st.key = 'map_road_3_width') AS w3,
                  (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1)::double precision AS world
             FROM st)
    SELECT cfg.*, ceil(greatest(sqrt(power(cfg.vbays_hi * cfg.bay, 2) + power(cfg.span_hi, 2)),
                                sqrt(power(cfg.tbays_hi * cfg.bay, 2) + power(cfg.plot_hi * cfg.perch, 2)),
                                sqrt(power(2 * cfg.plot_hi * cfg.perch, 2) + power(1.5 * cfg.bay, 2)),
                                sqrt(power(x.barn_bays_hi * cfg.bay, 2) + power(x.barn_span_hi, 2)),
                                sqrt(power(x.wing_bays_hi * cfg.bay + 0.5, 2) + power(x.wing_wide_hi, 2))) / 2 / cfg.sq) + 1 AS r,
           -- how far back from the street's edge a house's farthest part may lie (a village barn behind its house, a town
           -- house's back range), in metres; the same for a church (its churchyard and its whole length), and how far a
           -- part of a church may reach from its middle, in squares (step 14e)
           greatest(cfg.setback_hi + cfg.vbays_hi * cfg.bay + x.barn_gap_hi + x.barn_bays_hi * cfg.bay,
                    cfg.tbays_hi * cfg.bay + x.wing_bays_hi * cfg.bay + 0.5) AS deep,
           x.church_setback_hi + x.church_tower_hi + x.church_nave_len_hi + x.church_chancel_hi AS cdeep,
           ceil(sqrt(power(x.church_nave_len_hi, 2) + power(greatest(x.church_aisled_hi, x.church_nave_wide_hi), 2)) / 2 / cfg.sq) + 1 AS rc,
           (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 6)::double precision AS dc
      INTO g
      FROM cfg
     CROSS JOIN LATERAL (
       SELECT (v_j ->> 'map_house_barn_bays_high')::double precision AS barn_bays_hi, (v_j ->> 'map_house_barn_span_high')::double precision AS barn_span_hi,
              (v_j ->> 'map_house_barn_gap_high')::double precision AS barn_gap_hi, (v_j ->> 'map_house_wing_bays_high')::double precision AS wing_bays_hi,
              (v_j ->> 'map_house_wing_wide_high')::double precision AS wing_wide_hi, (v_j ->> 'map_house_church_setback_high')::double precision AS church_setback_hi,
              (v_j ->> 'map_house_church_tower_side_high')::double precision AS church_tower_hi, (v_j ->> 'map_house_church_nave_len_high')::double precision AS church_nave_len_hi,
              (v_j ->> 'map_house_church_chancel_len_high')::double precision AS church_chancel_hi, (v_j ->> 'map_house_church_aisled_wide_high')::double precision AS church_aisled_hi,
              (v_j ->> 'map_house_church_nave_wide_high')::double precision AS church_nave_wide_hi) x;

    -- the villages, towns and cities whose ground reaches the box of the houses that might overlap those reaching the
    -- block (three reaches round it; rpg_map_town_grounds), and their streets and plot widths (rpg_map_town_streets,
    -- step 3: the roads, the market place, the streets and lanes inside a town or city, a great city's cathedral close)
    v_tw := public.rpg_map_town_grounds(p_x0 - 3 * g.r, p_y0 - 3 * g.r, p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r);

    IF jsonb_array_length(v_tw) = 0 THEN
      v_c := '[]'::jsonb;
    ELSE
      v_tl := public.rpg_map_town_streets(v_tw);

      -- the plots near the block and the building each holds (step 14e, Peter 2026-10-07 21:05: cities need more building
      -- variety). Every plot rolls what stands on it from its own rolls (u1 to u9 as before, v1 to v12 from part 12,
      -- layers 1241 to 1252 for the left side, 1261 to 1272 for the right), so each block of the map gets the same
      -- answer for the same plot. What the plot holds (use):
      --   the main plot of a settlement (its first road, the plot just past where that road passes nearest the middle,
      --     left side) holds its main church: always in a town or city, in a village when v1 < map_house_church_village_share
      --     (about half of medieval villages had their own church; the rest shared a parish); a great city's cathedral
      --     stands in its own close (below);
      --   any other plot of a town, city or great city holds a parish church when v1 < (churches - 1) / plots, churches
      --     being its people over map_house_church_people_<kind> (one church to 1,200 people in a town, 600 in a city or
      --     great city: York had about 40 parishes for 10,000 to 15,000 people, Norwich 46 for 25,000, Bristol 18 for
      --     10,000; Rosser 1988, Palliser 2000) and plots both sides of its streets over the plot width;
      --   every other plot a house, as before. In a town, city or great city it is a hall house set along the street
      --     across two plots (Pantin 1962's parallel plan) when v2 < map_house_hall_share, and has a back range (a wing
      --     running back from one side of the front range, Pantin's right-angle plan) when v3 < map_house_wing_share;
      --     in a village a barn stands behind the house when v3 < map_house_barn_share (Wharram Percy and other
      --     excavated tofts: a house and a barn or byre; Dyer 1986, Wrathmell 2012).
      -- Roofs: each house rolls its roof from v4 against map_house_roof_<kind>_thatch and _slate (the rest clay tile):
      -- thatch in nine villages in ten and still in some towns, stone slate where the stone splits, tile in the towns
      -- and cities. Stone slate pitches map_house_slate_low to _high degrees.
      -- A church: a nave (map_house_church_nave_*), a chancel to its east (map_house_church_chancel_*) and a tower at its
      -- west end (map_house_church_tower_*), the whole laid east to west as medieval churches were, set back from the
      -- street by its churchyard (map_house_church_setback_*); a village church has an aisleless nave, a town or city
      -- church an aisled one (map_house_church_aisled_*). Its nave and chancel roof is lead at a low pitch, stone slate
      -- or tile; its tower has a spire (v11 < map_house_church_spire_share, pitch map_house_church_spire_pitch) or a flat
      -- leaded top inside a parapet. A cathedral: a nave with aisles, transepts across it, a choir to the east, a tower
      -- over the crossing and two west towers (map_house_cathedral_*; Salisbury, Wells, Lincoln and Exeter run about 100
      -- to 140 m end to end), under steep lead roofs.
      -- Churches and the cathedral come first, so houses give way to them; a building's own parts never block each
      -- other; a building stands only if every part of it does. Each part is a row: the id of a building is its first
      -- part's id, h (house), b (barn), c (church) or k (cathedral) then the road, the plot's square and side, and every
      -- other part adds a dot and a letter: .w a house's back range, .n nave, .c chancel, .t tower, .x transepts, .q
      -- choir, .a and .b the west towers.
      WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                             shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                             fx double precision, fy double precision)),
           lr AS MATERIALIZED (
             SELECT tw.town, tw.kind, (v_tl -> tw.town ->> 'f')::double precision AS f,
                    coalesce((v_tl -> tw.town ->> 'plots')::double precision, 0) AS plots, coalesce((v_tl -> tw.town ->> 'people')::double precision, 0) AS people,
                    (v_tl -> tw.town ->> 'main')::integer AS main, l.*
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
           -- how far along each line the plots near the box may lie: where its points and its straight ends come within a
           -- street, the deepest a building may stand back from it and three reaches of a part of the box (houses: g.r;
           -- churches: g.rc, a bigger reach, so a parish church's plot is looked at from further off)
           pr AS MATERIALIZED (
             SELECT lr.*, q.tmin - lr.f AS tmin, q.tmax + lr.f AS tmax, q.cmin - lr.f AS cmin, q.cmax + lr.f AS cmax
               FROM lr
              CROSS JOIN LATERAL (SELECT lr.half + g.deep / g.sq + g.r AS reach, lr.half + g.cdeep / g.sq + g.rc AS creach) e
              CROSS JOIN LATERAL (
                SELECT min(u.s) FILTER (WHERE u.near) AS tmin, max(u.s) FILTER (WHERE u.near) AS tmax, min(u.s) AS cmin, max(u.s) AS cmax
                  FROM (SELECT (pe.v ->> 1)::double precision AS s,
                               (pe.v ->> 2)::double precision BETWEEN p_x0 - 3 * g.r - e.reach AND p_x0 + p_cols + 3 * g.r + e.reach
                               AND (pe.v ->> 3)::double precision BETWEEN p_y0 - 3 * g.r - e.reach AND p_y0 + p_rows + 3 * g.r + e.reach AS near
                          FROM jsonb_array_elements(lr.pts) AS pe(v)
                         WHERE (pe.v ->> 2)::double precision BETWEEN p_x0 - 3 * g.rc - e.creach AND p_x0 + p_cols + 3 * g.rc + e.creach
                           AND (pe.v ->> 3)::double precision BETWEEN p_y0 - 3 * g.rc - e.creach AND p_y0 + p_rows + 3 * g.rc + e.creach
                        UNION ALL
                        SELECT v.s, public.rpg_seg_box(lr.ax + (lr.bx - lr.ax) / lr.len * lr.lo, lr.ay + (lr.by - lr.ay) / lr.len * lr.lo, lr.ax, lr.ay,
                                                       p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)
                          FROM (VALUES (lr.lo), (0::double precision)) AS v(s)
                         WHERE lr.lo < 0 AND public.rpg_seg_box(lr.ax + (lr.bx - lr.ax) / lr.len * lr.lo, lr.ay + (lr.by - lr.ay) / lr.len * lr.lo, lr.ax, lr.ay,
                                                                p_x0 - 3 * g.rc - e.creach, p_y0 - 3 * g.rc - e.creach, p_x0 + p_cols + 3 * g.rc + e.creach, p_y0 + p_rows + 3 * g.rc + e.creach)
                        UNION ALL
                        SELECT v.s, public.rpg_seg_box(lr.bx, lr.by, lr.ax + (lr.bx - lr.ax) / lr.len * lr.hi, lr.ay + (lr.by - lr.ay) / lr.len * lr.hi,
                                                       p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)
                          FROM (VALUES (lr.len), (lr.hi)) AS v(s)
                         WHERE lr.hi > lr.len AND public.rpg_seg_box(lr.bx, lr.by, lr.ax + (lr.bx - lr.ax) / lr.len * lr.hi, lr.ay + (lr.by - lr.ay) / lr.len * lr.hi,
                                                                     p_x0 - 3 * g.rc - e.creach, p_y0 - 3 * g.rc - e.creach, p_x0 + p_cols + 3 * g.rc + e.creach, p_y0 + p_rows + 3 * g.rc + e.creach)) u) q
              WHERE lr.f > 0 AND q.cmin IS NOT NULL),
           -- the plots: near = within the houses' reach of the box; the rest are looked at only as churches. The main plot
           -- of every settlement whose first road comes near is always looked at, wherever it lies, so its main church or
           -- cathedral is found from every block it reaches.
           pl0 AS (
             SELECT pr.town, pr.kind, pr.k, pr.class, pr.half, pr.f, pr.plots, pr.people, pr.main, j, s.side,
                    pr.t0 + (j + 0.5) * pr.f AS tm, pr.t0 + (j + 0.5) * pr.f < 0 OR pr.t0 + (j + 0.5) * pr.f > pr.len AS cont,
                    pr.tmin IS NOT NULL AND pr.t0 + (j + 0.5) * pr.f BETWEEN pr.tmin - pr.f AND pr.tmax + pr.f AS near
               FROM pr
              CROSS JOIN LATERAL generate_series(greatest(ceil((pr.lo - pr.t0) / pr.f - 1e-6), floor((pr.cmin - pr.t0) / pr.f) - 1)::integer,
                                                 least(floor((pr.hi - pr.t0) / pr.f + 1e-6) - 1, ceil((pr.cmax - pr.t0) / pr.f) + 1)::integer) AS j
              CROSS JOIN (VALUES (-1), (1)) AS s(side)
             UNION
             SELECT lr.town, lr.kind, lr.k, lr.class, lr.half, lr.f, lr.plots, lr.people, lr.main, 0, -1, lr.t0 + 0.5 * lr.f,
                    lr.t0 + 0.5 * lr.f < 0 OR lr.t0 + 0.5 * lr.f > lr.len, false
               FROM lr WHERE lr.k = lr.main AND lr.f > 0 AND lr.t0 + 0.5 * lr.f BETWEEN lr.lo AND lr.hi),
           pl AS MATERIALIZED (SELECT pl0.town, pl0.kind, pl0.k, pl0.class, pl0.half, pl0.f, pl0.plots, pl0.people, pl0.j, pl0.side, pl0.tm, pl0.cont,
                                      bool_or(pl0.near) AS near, pl0.k = pl0.main AND pl0.j = 0 AND pl0.side = -1 AS main
                                 FROM pl0 GROUP BY pl0.town, pl0.kind, pl0.k, pl0.class, pl0.half, pl0.f, pl0.plots, pl0.people, pl0.j, pl0.side, pl0.tm, pl0.cont, pl0.main),
           -- where the road runs at the middle of each plot (rpg_map_road_line at that count along the line), and the
           -- way it runs there: along it (ux, uy) and across it (nx, ny)
           pq AS (SELECT pl.town, pl.k, array_agg(DISTINCT pl.tm ORDER BY pl.tm) AS tms FROM pl GROUP BY pl.town, pl.k),
           pp AS MATERIALIZED (
             SELECT pq.town, pq.k, pq.tms[p.n] AS tm, p.x, p.y, p.ux, p.uy, -p.uy AS nx, p.ux AS ny
               FROM pq JOIN pr ON pr.town = pq.town AND pr.k = pq.k
              CROSS JOIN LATERAL public.rpg_map_road_line(pr.class, pr.ax, pr.ay, pr.bx, pr.by, pr.a, pr.b, 1, pq.tms) p),
           -- each plot's own rolls (u1 to u9 and v1 to v12, 0 to 1) at the square in its middle on the road's line, and
           -- what it holds
           pu AS MATERIALIZED (
             SELECT pl.*, pp.x AS lx, pp.y AS ly, pp.ux, pp.uy, pp.nx, pp.ny, round(pp.x)::integer AS px, round(pp.y)::integer AS py,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + CASE WHEN pl.side > 0 THEN 10 ELSE 0 END + n,
                                                           round(pp.x)::integer, round(pp.y)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + CASE WHEN pl.side > 0 THEN 20 ELSE 0 END + n,
                                                           round(pp.x)::integer, round(pp.y)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 12) AS n) AS v
               FROM pl JOIN pp ON pp.town = pl.town AND pp.k = pl.k AND pp.tm = pl.tm),
           pk AS MATERIALIZED (
             SELECT pu.*, w.use
               FROM pu
              CROSS JOIN LATERAL (
                SELECT CASE WHEN pu.main AND pu.kind <> 'village' THEN 'church'
                            WHEN pu.main AND pu.v[1] < (v_j ->> 'map_house_church_village_share')::double precision THEN 'church'
                            WHEN pu.kind <> 'village' AND pu.plots > 0
                             AND pu.v[1] < (greatest(pu.people / nullif((v_j ->> ('map_house_church_people_' || pu.kind))::double precision, 0), 1) - 1) / pu.plots THEN 'church'
                            ELSE 'house' END AS use) w
              WHERE pu.near OR w.use <> 'house'),
           -- a great city's cathedral stands in its own close (rpg_map_town_streets, step 3: the try found there, the
           -- nearest clear of the roads and the market place with no water under it; the streets and lanes keep out of
           -- it); its sizes come from the rolls at the middle square (part 12, layers 1241 to 1252 and 1211 to 1219)
           kc AS (
             SELECT tw.town, tw.kind, round(tw.mx)::integer AS px, round(tw.my)::integer AS py, (v_tl -> tw.town -> 'close' ->> 'j')::integer AS n,
                    (v_tl -> tw.town -> 'close' ->> 'x')::double precision AS lx, (v_tl -> tw.town -> 'close' ->> 'y')::double precision AS ly,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + n, round(tw.mx)::integer, round(tw.my)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + n, round(tw.mx)::integer, round(tw.my)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 12) AS n) AS v
               FROM tw
              WHERE tw.kind = 'great_city' AND jsonb_typeof(v_tl -> tw.town -> 'close') = 'object'),
           -- a house, in metres (as before; a hall house fills two plots along the street, one bay deep and a half more)
           hm AS (
             SELECT pk.*, d.*
               FROM pk
              CROSS JOIN LATERAL (
                SELECT (v_j ->> ('map_house_storeys_' || pk.kind || '_low'))::double precision AS s_lo,
                       (v_j ->> ('map_house_storeys_' || pk.kind || '_high'))::double precision AS s_hi,
                       (v_j ->> ('map_house_roof_' || pk.kind || '_thatch'))::double precision AS r_th,
                       (v_j ->> ('map_house_roof_' || pk.kind || '_slate'))::double precision AS r_sl) k
              CROSS JOIN LATERAL (
                SELECT CASE WHEN pk.v[4] < k.r_th THEN 'thatch' WHEN pk.v[4] < k.r_th + k.r_sl THEN 'slate' ELSE 'tile' END AS roof) m
              CROSS JOIN LATERAL (
                SELECT (k.s_lo + least(floor((k.s_hi - k.s_lo + 1) * pk.u[3]), k.s_hi - k.s_lo))::integer AS storeys,
                       g.span_lo + (g.span_hi - g.span_lo) * pk.u[1] AS span,
                       CASE WHEN pk.kind = 'village' THEN g.vbays_lo + least(floor((g.vbays_hi - g.vbays_lo + 1) * pk.u[2]), g.vbays_hi - g.vbays_lo)
                            ELSE g.tbays_lo + least(floor((g.tbays_hi - g.tbays_lo + 1) * pk.u[2]), g.tbays_hi - g.tbays_lo) END * g.bay AS length,
                       g.storey_lo + (g.storey_hi - g.storey_lo) * pk.u[4] AS storey,
                       m.roof,
                       CASE m.roof WHEN 'thatch' THEN g.thatch_lo + (g.thatch_hi - g.thatch_lo) * pk.u[5]
                                   WHEN 'slate' THEN (v_j ->> 'map_house_slate_low')::double precision
                                                     + ((v_j ->> 'map_house_slate_high')::double precision - (v_j ->> 'map_house_slate_low')::double precision) * pk.u[5]
                                   ELSE g.tile_lo + (g.tile_hi - g.tile_lo) * pk.u[5] END AS pitch,
                       CASE WHEN pk.kind = 'village' THEN g.setback_hi * pk.u[6] ELSE 0 END AS setback,
                       CASE WHEN pk.kind <> 'village' AND pk.u[7] < 0.5 THEN g.passage ELSE 0 END AS passage,
                       pk.kind <> 'village' AND pk.v[2] < (v_j ->> 'map_house_hall_share')::double precision AS hall) d
              WHERE pk.use = 'house'),
           -- along = along the road, deep = back from it; a village house long side to the lane when its toft leaves
           -- map_house_gap_m beside it, else gable end on; a town or city house fills its plot less any passage; a hall
           -- house runs along two plots, toward the end of the street, a bay and a half deep
           hs AS (
             SELECT hm.*, a.along, a.deep,
                    CASE WHEN hm.kind = 'village' THEN (hm.f * g.sq - a.along) * (hm.u[7] - 0.5)
                         WHEN hm.hall THEN CASE WHEN hm.j >= 0 THEN 1 ELSE -1 END * hm.f * g.sq / 2
                         WHEN hm.u[8] < 0.5 THEN -hm.passage / 2 ELSE hm.passage / 2 END AS off
               FROM hm
              CROSS JOIN LATERAL (
                SELECT CASE WHEN hm.hall THEN 2 * hm.f * g.sq - hm.passage
                            WHEN hm.kind <> 'village' THEN hm.f * g.sq - hm.passage
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.length ELSE hm.span END AS along,
                       CASE WHEN hm.hall THEN 1.5 * g.bay
                            WHEN hm.kind <> 'village' THEN hm.length
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.span ELSE hm.length END AS deep) a),
           -- the parts of every building, in metres from the plot's point on the road: a (along the road) and b (back from
           -- the street's edge) to its middle, the way its ridge runs (east = the compass for a church, else along or
           -- across the road), its length and width, its eaves, pitch, storeys and roof
           pa AS (
             -- the house itself
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'h' AS pre, '' AS suf, 2 AS rank, 0 AS o, hs.off AS a, hs.setback + hs.deep / 2 AS b, 'road' AS way,
                    greatest(hs.along, hs.deep) AS len, least(hs.along, hs.deep) AS wide, hs.along >= hs.deep AS along_ridge,
                    hs.storeys * hs.storey AS eaves, hs.pitch, hs.storeys, hs.roof
               FROM hs
             UNION ALL
             -- its back range (a town, city or great city): along one side of the plot, running back from the front
             -- range, map_house_wing_wide_* wide, map_house_wing_bays_* bays long, as many storeys or one fewer
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'h', '.w', 2, 0,
                    hs.off + CASE WHEN hs.v[5] < 0.5 THEN -1 ELSE 1 END * (hs.along - w.wide) / 2,
                    hs.setback + hs.deep + w.long / 2 - 0.5, 'road', w.long + 0.5, w.wide, false,
                    w.storeys * hs.storey, hs.pitch, w.storeys, hs.roof
               FROM hs
              CROSS JOIN LATERAL (
                SELECT least((v_j ->> 'map_house_wing_wide_low')::double precision
                             + ((v_j ->> 'map_house_wing_wide_high')::double precision - (v_j ->> 'map_house_wing_wide_low')::double precision) * hs.v[6],
                             hs.along - 1) AS wide,
                       ((v_j ->> 'map_house_wing_bays_low')::double precision
                        + least(floor(((v_j ->> 'map_house_wing_bays_high')::double precision - (v_j ->> 'map_house_wing_bays_low')::double precision + 1) * hs.v[7]),
                                (v_j ->> 'map_house_wing_bays_high')::double precision - (v_j ->> 'map_house_wing_bays_low')::double precision)) * g.bay AS long,
                       greatest(hs.storeys - CASE WHEN hs.v[8] < 0.5 THEN 1 ELSE 0 END, 1) AS storeys) w
              WHERE hs.kind <> 'village' AND NOT hs.hall AND hs.v[3] < (v_j ->> 'map_house_wing_share')::double precision AND w.wide >= 2
             UNION ALL
             -- a village barn behind the house: map_house_barn_bays_* bays of map_house_bay_m, map_house_barn_span_* wide,
             -- map_house_barn_gap_* behind it, its ridge along or across the toft, one tall storey, thatched
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'b', '', 2, 1,
                    (hs.f * g.sq - CASE WHEN w.across THEN w.wide ELSE w.long END) * (hs.v[9] - 0.5),
                    hs.setback + hs.deep + w.gap + CASE WHEN w.across THEN w.long ELSE w.wide END / 2, 'road', w.long, w.wide, NOT w.across,
                    w.eaves, g.thatch_lo + (g.thatch_hi - g.thatch_lo) * hs.v[10], 1, 'thatch'
               FROM hs
              CROSS JOIN LATERAL (
                SELECT ((v_j ->> 'map_house_barn_bays_low')::double precision
                        + least(floor(((v_j ->> 'map_house_barn_bays_high')::double precision - (v_j ->> 'map_house_barn_bays_low')::double precision + 1) * hs.v[6]),
                                (v_j ->> 'map_house_barn_bays_high')::double precision - (v_j ->> 'map_house_barn_bays_low')::double precision)) * g.bay AS long,
                       (v_j ->> 'map_house_barn_span_low')::double precision
                        + ((v_j ->> 'map_house_barn_span_high')::double precision - (v_j ->> 'map_house_barn_span_low')::double precision) * hs.v[7] AS wide,
                       (v_j ->> 'map_house_barn_gap_low')::double precision
                        + ((v_j ->> 'map_house_barn_gap_high')::double precision - (v_j ->> 'map_house_barn_gap_low')::double precision) * hs.v[8] AS gap,
                       (v_j ->> 'map_house_barn_eaves_low')::double precision
                        + ((v_j ->> 'map_house_barn_eaves_high')::double precision - (v_j ->> 'map_house_barn_eaves_low')::double precision) * hs.v[11] AS eaves,
                       hs.v[12] < 0.5 AS across) w
              WHERE hs.kind = 'village' AND hs.v[3] < (v_j ->> 'map_house_barn_share')::double precision
             UNION ALL
             -- a church or the cathedral: its parts laid east to west about the middle of the whole, which stands back
             -- from the street by its churchyard and its own reach across the street
             SELECT pk.town, pk.kind, pk.k, pk.class, pk.cont, pk.j, pk.side, pk.half, pk.lx, pk.ly, pk.ux, pk.uy, pk.nx, pk.ny, pk.px, pk.py,
                    'c', c.suf, 1, c.o,
                    c.ex * pk.ux + c.ey * pk.uy,
                    w.back + (c.ex * pk.nx + c.ey * pk.ny) * pk.side, 'east', c.len, c.wide, c.ridge_ew,
                    c.eaves, c.pitch, 1, c.roof
               FROM pk
              CROSS JOIN LATERAL public.rpg_map_church_plan(pk.use, pk.kind, pk.u::double precision[], pk.v::double precision[], v_j) c
              CROSS JOIN LATERAL (
                SELECT (v_j ->> 'map_house_church_setback_low')::double precision
                       + ((v_j ->> 'map_house_church_setback_high')::double precision - (v_j ->> 'map_house_church_setback_low')::double precision) * pk.u[6]
                       + (SELECT max(abs(z.ex * pk.nx + z.ey * pk.ny)
                                     + abs(CASE WHEN z.ridge_ew THEN z.len ELSE z.wide END / 2 * pk.nx)
                                     + abs(CASE WHEN z.ridge_ew THEN z.wide ELSE z.len END / 2 * pk.ny))
                            FROM public.rpg_map_church_plan(pk.use, pk.kind, pk.u::double precision[], pk.v::double precision[], v_j) z) AS back) w
              WHERE pk.use = 'church'
             UNION ALL
             -- a great city's cathedral in its close (j = the try it stands at): its parts about its middle
             SELECT kc.town, kc.kind, 0, 0, false, kc.n, 1, 0::double precision,
                    kc.lx, kc.ly, 1::double precision, 0::double precision, 0::double precision, 1::double precision,
                    kc.px, kc.py, 'k', c.suf, 0, 0, c.ex, c.ey, 'east', c.len, c.wide, c.ridge_ew, c.eaves, c.pitch, 1, c.roof
               FROM kc CROSS JOIN LATERAL public.rpg_map_church_plan('cathedral', kc.kind, kc.u::double precision[], kc.v::double precision[], v_j) c),
           -- in squares on the map: the middle, the way of the ridge and the half sides
           hc AS MATERIALIZED (
             SELECT pa.town, pa.kind, pa.k, pa.class, pa.cont, pa.j, pa.side, pa.rank, pa.o, pa.pre,
                    pa.pre || CASE WHEN pa.pre = 'k' THEN pa.j::text ELSE pa.k::text END || '-' || pa.px || '-' || pa.py || CASE WHEN pa.side > 0 THEN 'r' ELSE 'l' END AS base,
                    pa.pre || CASE WHEN pa.pre = 'k' THEN pa.j::text ELSE pa.k::text END || '-' || pa.px || '-' || pa.py || CASE WHEN pa.side > 0 THEN 'r' ELSE 'l' END || pa.suf AS id,
                    pa.lx + (pa.ux * pa.a + pa.nx * pa.side * pa.b) / g.sq + pa.nx * pa.side * pa.half AS cx,
                    pa.ly + (pa.uy * pa.a + pa.ny * pa.side * pa.b) / g.sq + pa.ny * pa.side * pa.half AS cy,
                    CASE WHEN pa.way = 'east' THEN CASE WHEN pa.along_ridge THEN 1 ELSE 0 END
                         WHEN pa.along_ridge THEN pa.ux ELSE pa.nx END AS rx,
                    CASE WHEN pa.way = 'east' THEN CASE WHEN pa.along_ridge THEN 0 ELSE 1 END
                         WHEN pa.along_ridge THEN pa.uy ELSE pa.ny END AS ry,
                    pa.len / 2 / g.sq AS hl, pa.wide / 2 / g.sq AS hw,
                    pa.eaves, pa.pitch, pa.storeys, pa.roof
               FROM pa),
           -- the parts in that box that keep clear of every road and street of their settlement (every piece of every
           -- line, half its width from it; step 3: a church keeps clear of the roads and the market place only, and may
           -- stand across a street or a lane inside the town, whose way its walls then end),
           -- each building with its place in the order: the cathedral, then churches,
           -- then houses and barns; bigger road first, then the road counted first, its own road before the street it runs
           -- on as, then the plot nearer the middle, a house before its barn
           cl AS MATERIALIZED (
             SELECT hc.*, dense_rank() OVER (PARTITION BY hc.town ORDER BY hc.rank, hc.class, hc.k, hc.cont, abs(hc.j), hc.j, hc.side, hc.o) AS n,
                    NOT EXISTS (
                      SELECT 1 FROM sg JOIN lr ON lr.town = sg.town AND lr.k = sg.k
                       CROSS JOIN LATERAL (SELECT lr.half - 0.01 AS wide) w
                       CROSS JOIN LATERAL (SELECT sg.x0 - hc.cx AS x0, sg.y0 - hc.cy AS y0, sg.x1 - hc.cx AS x1, sg.y1 - hc.cy AS y1) e
                       WHERE sg.town = hc.town AND NOT (hc.rank = 1 AND lr.class >= 5)
                         AND least(sg.x0, sg.x1) <= hc.cx + hc.hl + w.wide AND greatest(sg.x0, sg.x1) >= hc.cx - hc.hl - w.wide
                         AND least(sg.y0, sg.y1) <= hc.cy + hc.hl + w.wide AND greatest(sg.y0, sg.y1) >= hc.cy - hc.hl - w.wide
                         AND public.rpg_seg_box(e.x0 * hc.rx + e.y0 * hc.ry, e.y0 * hc.rx - e.x0 * hc.ry, e.x1 * hc.rx + e.y1 * hc.ry, e.y1 * hc.rx - e.x1 * hc.ry,
                                                -(hc.hl + w.wide), -(hc.hw + w.wide), hc.hl + w.wide, hc.hw + w.wide)) AS clear
               FROM hc
              WHERE hc.base IN (SELECT h2.base FROM hc h2
                                 WHERE h2.rank = 0
                                    OR (h2.rank = 1 AND h2.cx BETWEEN p_x0 - 3 * g.rc AND p_x0 + p_cols + 3 * g.rc AND h2.cy BETWEEN p_y0 - 3 * g.rc AND p_y0 + p_rows + 3 * g.rc)
                                    OR (h2.cx BETWEEN p_x0 - 3 * g.r AND p_x0 + p_cols + 3 * g.r AND h2.cy BETWEEN p_y0 - 3 * g.r AND p_y0 + p_rows + 3 * g.r))),
           -- a building clear of every road (all its parts), and of those the parts that meet a part of such a building
           -- before it: a building stands when none of its parts does
           cb0 AS (SELECT cl.base, cl.town, min(cl.rank) AS rank, min(cl.j) AS j FROM cl GROUP BY cl.base, cl.town HAVING bool_and(cl.clear)),
           cb AS (SELECT cb0.base FROM cb0),
           cc AS MATERIALIZED (SELECT cl.* FROM cl WHERE cl.base IN (SELECT cb.base FROM cb)),
           bl AS MATERIALIZED (
             SELECT cc.*,
                    EXISTS (SELECT 1 FROM cc c2
                             WHERE c2.town = cc.town AND c2.n < cc.n
                               AND public.rpg_map_rects_meet(cc.cx, cc.cy, cc.rx, cc.ry, cc.hl, cc.hw, c2.cx, c2.cy, c2.rx, c2.ry, c2.hl, c2.hw)) AS hit
               FROM cc),
           bk AS (SELECT bl.base FROM bl GROUP BY bl.base HAVING NOT bool_or(bl.hit))
      -- of those, the buildings with a part that reaches the block: all their parts
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', bl.id, 'base', bl.base, 'town', bl.town, 'kind', bl.kind, 'roof', bl.roof, 'cx', bl.cx, 'cy', bl.cy,
                                                   'ux', bl.rx, 'uy', bl.ry, 'half_len', bl.hl, 'half_wide', bl.hw, 'eaves', bl.eaves,
                                                   'pitch', bl.pitch, 'storeys', bl.storeys) ORDER BY bl.town, bl.n, bl.id), '[]'::jsonb)
        INTO v_hb
        FROM bl
       WHERE bl.base IN (SELECT bk.base FROM bk)
         AND bl.base IN (SELECT b2.base FROM bl b2
                          WHERE public.rpg_map_rects_meet(b2.cx, b2.cy, b2.rx, b2.ry, b2.hl, b2.hw, p_x0 + p_cols / 2.0, p_y0 + p_rows / 2.0, 1, 0, p_cols / 2.0, p_rows / 2.0));

      -- whether each building stands on its own dry ground, once a transaction: the four corners and the middles of the
      -- four sides of every part, a hair in, and its middle, on its settlement's ground and not the sea, and no river or
      -- lake under any of them. The water is read in two goes (step 14e): first the District grid's cells round the
      -- points (rpg_map_flow at that grid: a river, stream or brook whose line runs through a cell, or water at its
      -- middle), then the battle grid only over the points that lie in or beside such a cell, so a town far from any
      -- water reads none of it square by square; the answer is the same as reading every square.
      v_ok := coalesce(nullif(current_setting('rpg.houseok', true), ''), '{}')::jsonb;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_hb) h WHERE NOT v_ok ? (h ->> 'base')) THEN
        WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                               shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                               fx double precision, fy double precision)),
             hb AS (SELECT * FROM jsonb_to_recordset(v_hb) AS h(id text, base text, town text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                                half_len double precision, half_wide double precision)
                     WHERE NOT v_ok ? h.base),
             pt AS MATERIALIZED (
               SELECT hb.base, hb.town, q.a * (hb.half_len - 0.01) * hb.ux - q.b * (hb.half_wide - 0.01) * hb.uy + hb.cx AS x,
                      q.a * (hb.half_len - 0.01) * hb.uy + q.b * (hb.half_wide - 0.01) * hb.ux + hb.cy AS y
                 FROM hb CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             -- the land and sea under them, and a card's own edge, read once as a block
             ab AS (SELECT floor(min(pt.x))::integer AS x0, floor(min(pt.y))::integer AS y0,
                           (floor(max(pt.x)) - floor(min(pt.x)) + 1)::integer AS cols, (floor(max(pt.y)) - floor(min(pt.y)) + 1)::integer AS rows
                      FROM pt),
             -- (step 14e) the heights read District cell by District cell, only the cells the points lie in
             hd0 AS (SELECT DISTINCT floor(pt.x / g.dc)::integer AS dx, floor(pt.y / g.dc)::integer AS dy FROM pt),
             hd AS (SELECT q.dy, min(q.dx) AS x0, max(q.dx) AS x1
                      FROM (SELECT hd0.dx, hd0.dy, hd0.dx - row_number() OVER (PARTITION BY hd0.dy ORDER BY hd0.dx) AS run FROM hd0) q
                     GROUP BY q.dy, q.run),
             ht AS MATERIALIZED (SELECT h.x, h.y, h.height FROM hd
                                  CROSS JOIN LATERAL public.rpg_map_heights(7, (hd.x0 * g.dc)::integer, (hd.dy * g.dc)::integer, ((hd.x1 - hd.x0 + 1) * g.dc)::integer, g.dc::integer) h),
             -- the District grid cells round the points with water in or through them, and the cells beside those
             ad AS (SELECT floor(ab.x0 / g.dc)::integer - 1 AS x0, floor(ab.y0 / g.dc)::integer - 1 AS y0,
                           (floor((ab.x0 + ab.cols - 1) / g.dc) - floor(ab.x0 / g.dc) + 3)::integer AS cols,
                           (floor((ab.y0 + ab.rows - 1) / g.dc) - floor(ab.y0 / g.dc) + 3)::integer AS rows
                      FROM ab),
             dw AS MATERIALIZED (SELECT f.x, f.y FROM ad CROSS JOIN LATERAL public.rpg_map_flow(6, ad.x0, ad.y0, ad.cols, ad.rows) f
                                  WHERE f.depth > 0 OR f.line > 0),
             dn AS MATERIALIZED (SELECT DISTINCT dw.x + a AS x, dw.y + b AS y FROM dw CROSS JOIN generate_series(-1, 1) AS a CROSS JOIN generate_series(-1, 1) AS b),
             -- the points near water, and the battle grid's water under them
             pw AS MATERIALIZED (SELECT pt.* FROM pt JOIN dn ON dn.x = floor(pt.x / g.dc) AND dn.y = floor(pt.y / g.dc)),
             -- read only in the District cells those points lie in, a run of such cells along a row at a time
             aw0 AS (SELECT DISTINCT floor(pw.x / g.dc)::integer AS dx, floor(pw.y / g.dc)::integer AS dy FROM pw),
             aw AS (SELECT q.dy, min(q.dx) AS x0, max(q.dx) AS x1
                      FROM (SELECT aw0.dx, aw0.dy, aw0.dx - row_number() OVER (PARTITION BY aw0.dy ORDER BY aw0.dx) AS run FROM aw0) q
                     GROUP BY q.dy, q.run),
             wa AS MATERIALIZED (SELECT f.x, f.y FROM aw
                                  CROSS JOIN LATERAL public.rpg_map_flow(7, (aw.x0 * g.dc)::integer, (aw.dy * g.dc)::integer, ((aw.x1 - aw.x0 + 1) * g.dc)::integer, g.dc::integer) f
                                  WHERE f.depth > 0),
             wn AS MATERIALIZED (
               SELECT tw.town, w.x, w.y FROM tw CROSS JOIN ab CROSS JOIN LATERAL public.rpg_map_within(tw.card, 7, ab.x0, ab.y0, ab.cols, ab.rows) w
                WHERE tw.card IS NOT NULL AND EXISTS (SELECT 1 FROM hb WHERE hb.town = tw.town))
        SELECT v_ok || coalesce(jsonb_object_agg(b.base,
                 NOT EXISTS (SELECT 1 FROM pt
                               LEFT JOIN ht ON ht.x = floor(pt.x) AND ht.y = floor(pt.y)
                              WHERE pt.base = b.base
                                AND (coalesce(ht.height, -1e9) < g.sea
                                     OR CASE WHEN tw.card IS NULL
                                             THEN sqrt(power(pt.x - tw.mx, 2) + power(pt.y - tw.my, 2)) > public.rpg_map_town_edge(atan2(pt.y - tw.my, pt.x - tw.mx), tw.r, tw.shape)
                                             ELSE NOT EXISTS (SELECT 1 FROM wn WHERE wn.town = tw.town AND wn.x = floor(pt.x) AND wn.y = floor(pt.y)) END))
                 AND NOT EXISTS (SELECT 1 FROM pw JOIN wa ON wa.x = floor(pw.x) AND wa.y = floor(pw.y) WHERE pw.base = b.base)), '{}'::jsonb)
          INTO v_ok
          FROM (SELECT DISTINCT hb.base, hb.town FROM hb) b JOIN tw ON tw.town = b.town;
        PERFORM set_config('rpg.houseok', v_ok::text, true);
      END IF;
      SELECT coalesce(jsonb_agg(h ORDER BY n), '[]'::jsonb) INTO v_c
        FROM jsonb_array_elements(v_hb) WITH ORDINALITY AS e(h, n)
       WHERE (v_ok ->> (h ->> 'base'))::boolean;
    END IF;
    PERFORM set_config('rpg.houses', jsonb_set(v_all, ARRAY[v_key], v_c)::text, true);
  END IF;
  RETURN QUERY
  SELECT h.id, h.town, h.kind, h.roof, h.cx, h.cy, h.ux, h.uy, h.half_len, h.half_wide, h.eaves, h.pitch, h.storeys
    FROM jsonb_to_recordset(v_c) AS h(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                      half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer);
END;
$function$;

-- (step 3) The squares of the battle grid a street, a lane or a market place inside a town or city runs over.
CREATE OR REPLACE FUNCTION public.rpg_map_street_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, class integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that the market place, a street or a lane inside a town, city or great
-- city runs over (step 3, Peter 2026-10-07 21:05: battle grids in a city should look like fighting in the streets):
-- the middle of the square within half its width of its line (rpg_map_town_streets, the one home of where they run,
-- classes 4, 5 and 6), as rpg_map_road_cells reads a road. class = the widest there (4 the market place, 5 a street, 6
-- a lane). The market place is an open square with straight ends (its squares lie between the ends of its line); a
-- street or lane is rounded at its ends like a road. A church may stand across a street or a lane: its walls end it
-- there (rpg_map_building_squares). rpg_map_cells makes them road ground on dry land (a street stops at a river: only
-- the roads bridge it), and the Maps tab paves them. Only the battle grid has squares this small.
WITH tw AS MATERIALIZED (
       SELECT public.rpg_map_town_grounds(p_x0 - 25, p_y0 - 25, p_x0 + p_cols + 25, p_y0 + p_rows + 25) AS j WHERE p_level = 7),
     ts AS MATERIALIZED (SELECT public.rpg_map_town_streets(tw.j) AS j FROM tw WHERE jsonb_array_length(tw.j) > 0),
     -- a market place runs straight: it is read as one piece from end to end, so its edges and ends are true lines
     ln AS (SELECT (l ->> 'class')::integer AS class, (l ->> 'half')::double precision AS half,
                   CASE WHEN (l ->> 'class')::integer = 4 THEN jsonb_build_array(jsonb_build_array(0, 0, l -> 'ax', l -> 'ay'), jsonb_build_array(1, 0, l -> 'bx', l -> 'by'))
                        ELSE l -> 'pts' END AS pts, e.key || ':' || (l ->> 'k') AS id
              FROM ts CROSS JOIN LATERAL jsonb_each(ts.j) AS e CROSS JOIN LATERAL jsonb_array_elements(e.value -> 'lines') AS l
             WHERE (l ->> 'class')::integer >= 4),
     lp AS (SELECT ln.id, ln.class, ln.half, (p.v ->> 0)::integer AS n, (p.v ->> 2)::double precision AS x, (p.v ->> 3)::double precision AS y
              FROM ln CROSS JOIN LATERAL jsonb_array_elements(ln.pts) AS p(v)),
     sg AS (SELECT a.class, a.half, a.x AS ax, a.y AS ay, b.x AS bx, b.y AS by FROM lp a JOIN lp b ON b.id = a.id AND b.n = a.n + 1
             WHERE greatest(a.x, b.x) + a.half >= p_x0 AND least(a.x, b.x) - a.half <= p_x0 + p_cols
               AND greatest(a.y, b.y) + a.half >= p_y0 AND least(a.y, b.y) - a.half <= p_y0 + p_rows)
SELECT gx, gy, min(sg.class)
  FROM sg
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(least(sg.ax, sg.bx) - sg.half)::integer),
                                    least(p_x0 + p_cols - 1, floor(greatest(sg.ax, sg.bx) + sg.half)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(least(sg.ay, sg.by) - sg.half)::integer),
                                    least(p_y0 + p_rows - 1, floor(greatest(sg.ay, sg.by) + sg.half)::integer)) AS gy
 CROSS JOIN LATERAL (SELECT gx + 0.5 - sg.ax AS px, gy + 0.5 - sg.ay AS py, sg.bx - sg.ax AS dx, sg.by - sg.ay AS dy) v
 CROSS JOIN LATERAL (SELECT CASE WHEN v.dx * v.dx + v.dy * v.dy = 0 THEN 0
                                 ELSE least(greatest((v.px * v.dx + v.py * v.dy) / (v.dx * v.dx + v.dy * v.dy), 0), 1) END AS t) t
 WHERE power(v.px - t.t * v.dx, 2) + power(v.py - t.t * v.dy, 2) <= sg.half * sg.half
   AND (sg.class <> 4 OR (v.px * v.dx + v.py * v.dy BETWEEN 0 AND v.dx * v.dx + v.dy * v.dy))
 GROUP BY gx, gy;
$function$;

-- the world map rule card: the one sentence about churchyards, swapped in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$a street stops at the water and at a churchyard.$a$, $b$a street stops at the water, and a church may stand across a street or a lane, which then ends at its walls.$b$), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position($a$a street stops at the water and at a churchyard.$a$ in body) > 0;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

