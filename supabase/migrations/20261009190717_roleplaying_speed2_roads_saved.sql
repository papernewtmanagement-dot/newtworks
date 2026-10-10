-- Roleplaying speed step 2 (Peter 2026-10-09): road stretches kept on the saved map.
CREATE OR REPLACE FUNCTION public.rpg_map_road_save(p_fill boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Keeps the road stretches a read of the map worked out (rpg_map_roads lists them in rpg.rd_new for the transaction, by
-- level:x0:y0:cols:rows:what:pad) on the saved map row of the grid each block starts in (notes: roads), so the next read
-- finds them instead of working them out again (speed step 2, 2026-10-09): the one home of that saving. p_fill: also
-- save those rows first where there are none (rpg_map_cache_fill), as the background read does. Returns how many rows
-- took roads.
DECLARE v_new jsonb; v_n integer := 0;
BEGIN
  v_new := nullif(current_setting('rpg.rd_new', true), '')::jsonb;
  IF v_new IS NULL OR v_new = '{}'::jsonb THEN RETURN 0; END IF;
  IF p_fill THEN
    PERFORM public.rpg_map_cache_fill(q.lv, q.gx * 12, q.gy * 12, 12, 12)
       FROM (SELECT DISTINCT split_part(e.k, ':', 1)::integer AS lv, split_part(e.k, ':', 2)::integer / 12 AS gx, split_part(e.k, ':', 3)::integer / 12 AS gy
               FROM jsonb_each(v_new) AS e(k, v)) q
      WHERE NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = q.lv AND m.gx = q.gx AND m.gy = q.gy);
  END IF;
  UPDATE public.rpg_map_cache m
     SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('roads', coalesce(m.notes -> 'roads', '{}'::jsonb) || n.add)
    FROM (SELECT split_part(e.k, ':', 1)::integer AS lv, split_part(e.k, ':', 2)::integer / 12 AS gx, split_part(e.k, ':', 3)::integer / 12 AS gy,
                 jsonb_object_agg(e.k, e.v) AS add
            FROM jsonb_each(v_new) AS e(k, v) GROUP BY 1, 2, 3) n
   WHERE m.level = n.lv AND m.gx = n.gx AND m.gy = n.gy
     AND NOT coalesce(m.notes -> 'roads', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;
REVOKE ALL ON FUNCTION public.rpg_map_road_save(boolean) FROM PUBLIC, anon, authenticated;

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
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, c.lie, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks,
                CASE WHEN c.kind = 'town' OR (v_l.level = 7 AND c.kind IN ('road', 'pass')) THEN tg.id END AS town,
                -- (step 3) a road, market place, street or lane square of a town, city or great city is paved
                CASE WHEN v_l.level = 7 AND c.kind IN ('road', 'pass') AND tg.kind IN ('town', 'city', 'great_city')
                     THEN CASE WHEN mk.x IS NOT NULL THEN 2 ELSE 1 END END AS paved,
                coalesce(hb.id, ft.house) AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
                CASE WHEN c.kind IN ('road', 'pass') AND wt.depth > 0 THEN 'bridge' WHEN c.kind = 'water' AND fd.x IS NOT NULL THEN 'ford' END AS cross
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
           LEFT JOIN fd ON fd.x = c.x AND fd.y = c.y
           LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
           LEFT JOIN public.rpg_map_steep(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
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
                   -- the battle grid's cliffs: how steep, in degrees (rpg_map_cliff_angle; step 7c), so the page draws the rock face
                   'cliff', CASE WHEN cl.seen AND cl.kind = 'mountains' THEN round(public.rpg_map_cliff_angle(cl.steep))::integer END,
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
         (SELECT jsonb_agg(jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near)) FROM ls WHERE ls.kind IN ('cave', 'mine')),
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
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'placed', p.pos_x IS NOT NULL,
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

CREATE OR REPLACE FUNCTION public.rpg_map_view_prepare_run(p_view text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Works out one map of the Maps tab in the background, past the 8 seconds a login may run a read (speed step 1,
-- 2026-10-09; Peter: fix the time outs for good), so the next read of it finds its rivers saved: the map is read as
-- the game master reads it (the same read the Maps tab makes: rpg_map_view, rpg_map_place_view or rpg_map_battle_view,
-- by p_view as the tab names it: '' the world, 3-29-46 a grid, p-<id> a place, s-<x0>-<y0> a slid battle grid), then
-- the rivers it worked out are kept, with the rows of the grids above saved where missing (rpg_map_drain_save(true)).
-- Called only by rpg_map_view_prepare, through the service login.
DECLARE m text[]; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  IF coalesce(p_view, '') = '' THEN
    PERFORM public.rpg_map_view(1, 0, 0);
  ELSIF p_view ~ '^[0-9]+-[0-9]+-[0-9]+$' THEN
    m := string_to_array(p_view, '-');
    PERFORM public.rpg_map_view(m[1]::integer, m[2]::integer, m[3]::integer);
  ELSIF p_view ~ '^p-[0-9a-f-]{36}$' THEN
    PERFORM public.rpg_map_place_view(substr(p_view, 3)::uuid);
  ELSIF p_view ~ '^s-[0-9]+-[0-9]+$' THEN
    m := string_to_array(p_view, '-');
    PERFORM public.rpg_map_battle_view(m[2]::integer, m[3]::integer);
  ELSE
    RAISE EXCEPTION 'that is not a map';
  END IF;
  v_n := public.rpg_map_drain_save(true);
  RETURN jsonb_build_object('ok', true, 'saved', v_n, 'roads', public.rpg_map_road_save(true));
END $function$;

