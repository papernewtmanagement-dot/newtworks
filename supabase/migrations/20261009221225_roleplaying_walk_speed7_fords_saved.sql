-- Walk speed step 7 (Peter 2026-10-09 1B): the planned fords worked out for each City cell are kept on the saved map too.
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
-- transaction (rpg.fords5: its anchor, or none), since a walk and the battle grid ask for the same cells many times,
-- and (walk speed step 7) kept on the saved map (the City grid's row over the cell, notes: fords) for later reads.
DECLARE
  v_c5    double precision;
  v_cache jsonb;
  v_new   jsonb;
BEGIN
  SELECT l.cell INTO v_c5 FROM public.rpg_map_ladder() l WHERE l.level = 5;
  v_cache := coalesce(nullif(current_setting('rpg.fords5', true), ''), '{}')::jsonb;
  -- (walk speed step 7, Peter 2026-10-09) the cells an earlier read worked out, kept on the saved map: the City grid's
  -- rows over the box (notes: fords, by 'gx:gy:size'; rpg_map_drain_save keeps them there)
  SELECT v_cache || coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) INTO v_cache
    FROM public.rpg_map_cache m CROSS JOIN LATERAL jsonb_each(m.notes -> 'fords') AS e(key, value)
   WHERE m.level = 5 AND m.notes ? 'fords'
     AND m.gx BETWEEN floor(p_x0 / v_c5 / 12)::integer AND floor(p_x1 / v_c5 / 12)::integer
     AND m.gy BETWEEN floor(p_y0 / v_c5 / 12)::integer AND floor(p_y1 / v_c5 / 12)::integer
     AND NOT (v_cache ? e.key);
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
    -- (walk speed step 7) listed for rpg_map_drain_save to keep on the saved map
    PERFORM set_config('rpg.fords_new', trim(coalesce(current_setting('rpg.fords_new', true), '') || ' ' || (SELECT string_agg(nk.key, ' ') FROM jsonb_object_keys(v_new) AS nk(key))), true);
  END IF;
  PERFORM set_config('rpg.fords5', v_cache::text, true);
  RETURN QUERY
    SELECT (split_part(e.key, ':', 3))::integer, (e.value ->> 0)::double precision, (e.value ->> 1)::double precision, (e.value ->> 2)::double precision, (e.value ->> 3)::double precision
      FROM jsonb_each(v_cache) AS e(key, value)
     WHERE jsonb_typeof(e.value) = 'array'
       AND (split_part(e.key, ':', 3))::integer = ANY (coalesce(p_classes, '{}'::integer[]))
       AND (e.value ->> 0)::double precision BETWEEN p_x0 AND p_x1 AND (e.value ->> 1)::double precision BETWEEN p_y0 AND p_y1
       AND (split_part(e.key, ':', 1))::integer BETWEEN floor(p_x0 / v_c5)::integer AND floor(p_x1 / v_c5)::integer
       AND (split_part(e.key, ':', 2))::integer BETWEEN floor(p_y0 / v_c5)::integer AND floor(p_y1 / v_c5)::integer;
END $function$
;
CREATE OR REPLACE FUNCTION public.rpg_map_drain_save(p_fill boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Keeps the rivers a read of the map worked out (rpg_map_drain_cell lists them in rpg.dc_new for the transaction) on the
-- saved map's row of the grid above each (notes: rivers, by cell), so the next read finds them instead of working them
-- out again: the one home of that saving (moved here from rpg_map_view_block, speed step 1, 2026-10-09). p_fill: also
-- save the rows of those grids first where there are none (rpg_map_cache_fill, about 2 seconds a Country grid), as the
-- background read does (rpg_map_view_prepare_run). Returns how many rows took rivers.
DECLARE v_dcell jsonb; v_n integer := 0; v_bl jsonb; v_fd jsonb; v_f5 jsonb;
BEGIN
  -- the rivers inside the cells of the grid above that this read worked out (rpg_map_drain_cell, kept for
  -- the transaction, listed in rpg.dc_new by 'grid:x,y': rivers inside Continent cells, streams inside Country cells and brooks
  -- inside Region cells, step 14f3) are saved on the saved map's row of that grid (notes: rivers, by cell), where it
  -- has one, so the next read finds them there instead of working them out again
  SELECT jsonb_object_agg(u.k, current_setting('rpg.dc_' || replace(replace(u.k, ':', '_'), ',', '_'), true)::jsonb) INTO v_dcell
    FROM unnest(string_to_array(nullif(current_setting('rpg.dc_new', true), ''), ' ')) AS u(k);
  IF v_dcell IS NOT NULL AND v_dcell <> '{}'::jsonb THEN
    -- (speed step 1) called in the background (p_fill), the rows of the grids above that are not saved yet are saved
    -- first (rpg_map_cache_fill), so every river worked out finds a row to be kept on; a read of the map in a click
    -- does not pay for that and keeps only what has a row already
    IF p_fill THEN
      PERFORM public.rpg_map_cache_fill(q.lv, q.gx * 12, q.gy * 12, 12, 12)
         FROM (SELECT DISTINCT split_part(e.k, ':', 1)::integer - 1 AS lv, split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx,
                      split_part(e.k, ',', 2)::integer / 12 AS gy
                 FROM jsonb_each(v_dcell) AS e(k, v)) q
        WHERE q.lv >= 2 AND NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = q.lv AND m.gx = q.gx AND m.gy = q.gy);
    END IF;
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('rivers', coalesce(m.notes -> 'rivers', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(e.k, ':', 1)::integer - 1 AS lv, split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx,
                   split_part(e.k, ',', 2)::integer / 12 AS gy, jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_dcell) AS e(k, v) GROUP BY 1, 2, 3) n
     WHERE m.level = n.lv AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'rivers', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  -- (walk speed step 5, Peter 2026-10-09) the battle grid's river lines a read worked out for each City cell
  -- (rpg_map_river_line, kept for the transaction, listed in rpg.bl_new by 'upto:cx,cy') are kept on the City grid's
  -- row over that cell (notes: blines), so a later read skips working them out; called in the background (p_fill) the
  -- rows missing are saved first (rpg_map_cache_fill), as for the rivers above
  SELECT jsonb_object_agg(u.k, current_setting('rpg.bl_' || replace(replace(u.k, ':', '_'), ',', '_'), true)::jsonb) INTO v_bl
    FROM unnest(string_to_array(nullif(trim(coalesce(current_setting('rpg.bl_new', true), '')), ''), ' ')) AS u(k);
  IF v_bl IS NOT NULL AND v_bl <> '{}'::jsonb THEN
    IF p_fill THEN
      PERFORM public.rpg_map_cache_fill(5, q.gx * 12, q.gy * 12, 12, 12)
         FROM (SELECT DISTINCT split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx, split_part(e.k, ',', 2)::integer / 12 AS gy
                 FROM jsonb_each(v_bl) AS e(k, v)) q
        WHERE NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = 5 AND m.gx = q.gx AND m.gy = q.gy);
    END IF;
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('blines', coalesce(m.notes -> 'blines', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx, split_part(e.k, ',', 2)::integer / 12 AS gy,
                   jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_bl) AS e(k, v) GROUP BY 1, 2) n
     WHERE m.level = 5 AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'blines', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
  END IF;
  -- (walk speed step 7) the planned fords a read worked out for each City cell and size (rpg_map_fords, kept for the
  -- transaction in rpg.fords5, listed in rpg.fords_new by 'gx:gy:size') are kept on the City grid's row over the cell
  -- (notes: fords), the rows missing saved first when p_fill, as above
  v_f5 := coalesce(nullif(current_setting('rpg.fords5', true), ''), '{}')::jsonb;
  SELECT jsonb_object_agg(u.k, v_f5 -> u.k) INTO v_fd
    FROM unnest(string_to_array(nullif(trim(coalesce(current_setting('rpg.fords_new', true), '')), ''), ' ')) AS u(k)
   WHERE v_f5 ? u.k;
  IF v_fd IS NOT NULL AND v_fd <> '{}'::jsonb THEN
    IF p_fill THEN
      PERFORM public.rpg_map_cache_fill(5, q.gx * 12, q.gy * 12, 12, 12)
         FROM (SELECT DISTINCT floor(split_part(e.k, ':', 1)::integer / 12.0)::integer AS gx, floor(split_part(e.k, ':', 2)::integer / 12.0)::integer AS gy
                 FROM jsonb_each(v_fd) AS e(k, v)) q
        WHERE q.gx >= 0 AND NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = 5 AND m.gx = q.gx AND m.gy = q.gy);
    END IF;
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('fords', coalesce(m.notes -> 'fords', '{}'::jsonb) || n.add)
      FROM (SELECT floor(split_part(e.k, ':', 1)::integer / 12.0)::integer AS gx, floor(split_part(e.k, ':', 2)::integer / 12.0)::integer AS gy,
                   jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_fd) AS e(k, v) GROUP BY 1, 2) n
     WHERE m.level = 5 AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'fords', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
  END IF;
  RETURN v_n;
END $function$
;
-- (one quote mark to balance the text above for the SQL tool) '

