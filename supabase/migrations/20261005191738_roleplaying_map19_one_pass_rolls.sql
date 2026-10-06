-- Roleplaying world map step 9b (Peter 2026-10-05 18:41, his 1B: speed the world map up before step 10): the rolls a
-- point needs are read in one pass. New: rpg_map_rolls_set (the body of rpg_map_rolls_on, now reading one or several
-- parts in one pass over the cells and layers, and only the cells asked for), rpg_map_pole_pull (the pull toward the
-- sea at the poles, moved out of rpg_map_heights_on so the ground reads the height in its own pass). Changed in place:
-- rpg_map_rolls_on (one reading of rpg_map_rolls_set), rpg_map_heights_on (its roll less rpg_map_pole_pull),
-- rpg_map_nature (two passes: the height of every point, then the kind, cover, warmth and wetness of the land points).
-- Every grid, every walk and every fight board reads exactly what it read before (checked cell for cell at all seven
-- grids); only the time changes. No drops, no table changes, no page change.

CREATE OR REPLACE FUNCTION public.rpg_map_rolls_set(p_parts integer[], p_firsts integer[], p_fines integer[], p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_at integer[] DEFAULT NULL::integer[])
 RETURNS TABLE(x integer, y integer, vals double precision[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The layered rolls of the world map, read at the center of every cell in a block of an even spread of points, for
-- one or several readings in one pass (step 9b, 2026-10-05). The one home of how the fixed-seed rolls of the map
-- (rpg_map_roll) are layered and blended; worked out when asked and never stored. The body of rpg_map_rolls_on moved
-- here; rpg_map_rolls_on is one reading of it, rpg_map_rolls one reading on the cells of one grid.
-- A reading k is p_parts[k], p_firsts[k], p_fines[k]: the set of rolls (0 the height of the ground, 1 the kind of
-- ground, 2 how far the edge of a place wanders, 3 the cover, 4 warmth, 5 wetness; part p uses roll layers
-- p x 100 + 1 and up), the first layer read, and the smallest gap read. vals[k] = what reading k comes to at the
-- cell. The ground (rpg_map_nature) reads the kind, the cover grids, warmth and wetness in one pass instead of one
-- call each: where the points fall between the rolls (ax, ay) is the same for every reading and only the rolls and
-- what each layer counts differ, so one pass over the cells and layers serves them all.
-- p_cell = squares from one point to the next (a grid of the ladder: its cell; a closer spread: fewer squares);
-- p_deep = the finest grid whose layers are read. Cells are counted on that spread: cell x has its center at
-- (x + 0.5) x p_cell squares. p_at = only these cells of the block, numbered across the block row by row from 0
-- (the ground reads kind, cover and climate on land only); null = every cell. The map wraps east to west; north and
-- south it stops at the edge.
-- The layers are those of rpg_map_layers down to grid p_deep: three a grid, the points of each 2 or 3 times closer
-- than those of the layer before. A reading takes only the layers from its first on whose points are at least its
-- gap apart. A layer is read by blending the four rolls around the cell center, and a roll counts as its number
-- less 50.5. The first map_full_layers layers a reading takes (2) count in full; each layer after counts
-- map_detail_share (0.6) of the one before: 1, 1, 0.6, 0.36, 0.216 and so on. Rolls of 80 and 30 on the first two
-- layers alone give 29.5 - 20.5 = 9. So the first layers read set the big shapes and each layer down adds finer shape.
-- A whole block is one call so that every roll is made once (rl) and shared by all the cells around it: one list,
-- part by part, layer by layer, each layer row by row. What a layer adds at a cell is rounded to a whole number of
-- 2^30ths (about a billionth), so the layers add up to exactly the same number in whatever order they are added,
-- and a reading that does not take a layer adds 0 for it. A reading that takes no layer at all comes to 0; when no
-- reading takes any layer there are no rows.
-- The statement is built for the number of readings asked for (one sum a reading; a reading only skips layers when
-- there is more than one), so a single reading costs what it did when it had the function to itself.
DECLARE
  v_n     integer := cardinality(p_parts);
  v_cols  text := '';   -- in lay: what each reading counts at the layer and where its rolls start
  v_sums  text := '';   -- in pt: one sum a reading
  v_arr   text := '';   -- the readings as one list
  v_sql   text;
  v_roll  text := '(SELECT rl.rolls FROM rl)';
  v_blend text;
BEGIN
  IF v_n IS NULL OR v_n < 1 OR cardinality(p_firsts) <> v_n OR cardinality(p_fines) <> v_n THEN
    RAISE EXCEPTION 'rpg_map_rolls_set takes one or more readings, each a part, a first layer and a smallest gap';
  END IF;
  IF p_at IS NOT NULL AND cardinality(p_at) = 0 THEN
    RETURN;   -- no cells asked for: nothing to read, and no rolls to make
  END IF;
  FOR k IN 1..v_n LOOP
    v_cols := v_cols || format(', coalesce(max(m.w) FILTER (WHERE m.k = %1$s), 0) AS w%1$s, coalesce(max(m.off) FILTER (WHERE m.k = %1$s), 0) AS o%1$s', k);
    -- the four rolls round the point, blended, less 50.5
    v_blend := format('((%1$s[l.o%2$s + ay.j + ax.i + 1] * (1 - ax.sx) + %1$s[l.o%2$s + ay.j + ax.i + 2] * ax.sx) * (1 - ay.sy)'
                   || ' + (%1$s[l.o%2$s + ay.j + ax.i + l.wd + 1] * (1 - ax.sx) + %1$s[l.o%2$s + ay.j + ax.i + l.wd + 2] * ax.sx) * ay.sy - 50.5)', v_roll, k);
    v_sums := v_sums || CASE WHEN v_n = 1
                             THEN format(', sum(floor(l.w%1$s * %2$s * 1073741824 + 0.5) / 1073741824) AS s%1$s', k, v_blend)
                             ELSE format(', sum(CASE WHEN l.w%1$s > 0 THEN floor(l.w%1$s * %2$s * 1073741824 + 0.5) / 1073741824 ELSE 0 END) AS s%1$s', k, v_blend) END;
    v_arr := v_arr || CASE WHEN k > 1 THEN ', ' ELSE '' END || format('q.s%s', k);
  END LOOP;
  v_sql := $q$
  WITH RECURSIVE cfg AS (
       SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers,
              $5 AS cell),
     wt(n, w) AS (
       -- What the layer in each place of a reading counts, by multiplying one layer at a time so the numbers are the
       -- same on any machine.
       SELECT 1, 1::double precision
       UNION ALL
       SELECT wt.n + 1, CASE WHEN wt.n + 1 > cfg.full_layers THEN wt.w * cfg.share ELSE wt.w END
         FROM wt CROSS JOIN cfg
        WHERE wt.n < 3 * $4),
     rd AS (
       -- the readings asked for: k = the place of the reading in the lists
       SELECT k::integer AS k, ($1)[k] AS part, ($2)[k] AS frst, ($3)[k] AS fine
         FROM generate_subscripts($1, 1) AS k),
     mem AS MATERIALIZED (
       -- Every layer each reading takes, with what it counts for that reading (by its place among the layers the
       -- reading takes, coarsest first).
       SELECT q.k, q.part, q.n, wt.w
         FROM (SELECT rd.k, rd.part, y.n, row_number() OVER (PARTITION BY rd.k ORDER BY y.n) AS r
                 FROM rd CROSS JOIN public.rpg_map_layers() y
                WHERE y.level <= $4 AND y.n >= rd.frst AND y.gap >= rd.fine) q
         JOIN wt ON wt.n = q.r),
     lyr AS MATERIALIZED (
       -- One row a layer any reading takes, coarsest first. n = its number; f = cells of this spread from one of its
       -- points to the next; nx, ny = its points around and down the world; a_lo, b_lo = the first point the block
       -- needs; wd, ht = points across and down the block.
       SELECT y.n, k.f, y.nx, y.ny,
              floor(($6 + 0.5::double precision) / k.f - 0.5)::integer AS a_lo,
              floor(($7 + 0.5::double precision) / k.f - 0.5)::integer AS b_lo,
              floor(($6 + $8 - 0.5::double precision) / k.f - 0.5)::integer - floor(($6 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS wd,
              floor(($7 + $9 - 0.5::double precision) / k.f - 0.5)::integer - floor(($7 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS ht
         FROM cfg CROSS JOIN public.rpg_map_layers() y
        CROSS JOIN LATERAL (SELECT y.gap::double precision / cfg.cell AS f) k
        WHERE EXISTS (SELECT 1 FROM mem WHERE mem.n = y.n)),
     blk AS MATERIALIZED (
       -- One block of rolls for each part and layer any reading takes, in the order they sit in the list; off = the
       -- rolls before it.
       SELECT q.part, q.n, lyr.nx, lyr.ny, lyr.a_lo, lyr.b_lo, lyr.wd, lyr.ht,
              (sum(lyr.wd * lyr.ht) OVER (ORDER BY q.part, q.n) - lyr.wd * lyr.ht)::integer AS off
         FROM (SELECT DISTINCT mem.part, mem.n FROM mem) q
         JOIN lyr ON lyr.n = q.n),
     lay AS MATERIALIZED (
       -- One row a layer: its geometry, and for each reading what the layer counts (0 when the reading does not take
       -- it) and where its block of rolls starts in the list.
       SELECT lyr.n, lyr.f, lyr.a_lo, lyr.b_lo, lyr.wd, lyr.ht%COLS%
         FROM lyr
         LEFT JOIN (SELECT mem.k, mem.n, mem.w, blk.off FROM mem JOIN blk ON blk.part = mem.part AND blk.n = mem.n) m ON m.n = lyr.n
        GROUP BY lyr.n, lyr.f, lyr.a_lo, lyr.b_lo, lyr.wd, lyr.ht),
     rl AS MATERIALIZED (
       -- Every roll the block needs, made once and kept in one list: part by part, layer by layer, each layer row by row.
       SELECT ARRAY(SELECT public.rpg_map_roll(cfg.seed, b.part * 100 + b.n, mod(mod(b.a_lo + i, b.nx) + b.nx, b.nx), least(greatest(b.b_lo + j, 0), b.ny - 1))
                      FROM cfg CROSS JOIN blk b CROSS JOIN LATERAL generate_series(0, b.ht - 1) AS j CROSS JOIN LATERAL generate_series(0, b.wd - 1) AS i
                     ORDER BY b.part, b.n, j, i) AS rolls),
     ax AS MATERIALIZED (
       -- One row a layer and column of the block. i = where the point just west of the cell center sits in a row
       -- of the rolls of the layer; sx = how far east of that point the center is, eased (0 on the point, 1 on the next).
       SELECT l.n, gx, a.a - l.a_lo AS i, (u.u - a.a) * (u.u - a.a) * (3 - 2 * (u.u - a.a)) AS sx
         FROM lay l CROSS JOIN generate_series($6, $6 + $8 - 1) AS gx
        CROSS JOIN LATERAL (SELECT (gx + 0.5::double precision) / l.f - 0.5 AS u) u
        CROSS JOIN LATERAL (SELECT floor(u.u)::integer AS a) a),
     ay AS MATERIALIZED (
       -- The same down the block. j = where the row of points just north of the cell center starts in a block of
       -- rolls of the layer; sy = how far south of that row the center is, eased.
       SELECT l.n, gy, (b.b - l.b_lo) * l.wd AS j, (v.v - b.b) * (v.v - b.b) * (3 - 2 * (v.v - b.b)) AS sy
         FROM lay l CROSS JOIN generate_series($7, $7 + $9 - 1) AS gy
        CROSS JOIN LATERAL (SELECT (gy + 0.5::double precision) / l.f - 0.5 AS v) v
        CROSS JOIN LATERAL (SELECT floor(v.v)::integer AS b) b),
     pt AS (
       -- One row a cell: for each reading, the sum over the layers of what each adds at the cell, from the four rolls
       -- around it.
       SELECT ax.gx, ay.gy%SUMS%
         FROM lay l
         JOIN ax ON ax.n = l.n
         JOIN ay ON ay.n = l.n%AT%
        GROUP BY ax.gx, ay.gy)
  SELECT q.gx, q.gy, ARRAY[%ARR%]
    FROM pt q$q$;
  v_sql := replace(replace(replace(replace(v_sql, '%COLS%', v_cols), '%SUMS%', v_sums), '%ARR%', v_arr),
                   '%AT%', CASE WHEN p_at IS NULL THEN '' ELSE E'\n         JOIN (SELECT $6 + c % $8 AS gx, $7 + c / $8 AS gy FROM unnest($10) AS c) ac ON ac.gx = ax.gx AND ac.gy = ay.gy' END);
  RETURN QUERY EXECUTE v_sql USING p_parts, p_firsts, p_fines, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows, p_at;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_rolls_on(p_part integer, p_first integer, p_fine integer, p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, value double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One reading of the layered rolls of the world map at the center of every cell in a block of an even spread of
-- points p_cell squares apart, with the layers down to grid p_deep from layer p_first whose points are at least
-- p_fine squares apart. How the rolls are layered, blended and weighed has one home, rpg_map_rolls_set (step 9b);
-- this is that read with one reading. p_part picks the set of rolls: 0 height (rpg_map_heights_on), 1 kind of
-- ground (rpg_map_nature), 2 place edges (rpg_map_within), 3 cover, 4 warmth, 5 wetness, and so on.
SELECT r.x, r.y, r.vals[1]
  FROM public.rpg_map_rolls_set(ARRAY[p_part], ARRAY[p_first], ARRAY[p_fine], p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) r;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_pole_pull(p_y integer, p_cell integer, p_pole double precision, p_down integer)
 RETURNS double precision
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The pull toward the sea at the far north and south of the world map (step 9b, 2026-10-05; the formula moved here
-- from rpg_map_heights so that the ground, rpg_map_nature, reads the height in the same pass as the rest). The one
-- home of it: rpg_settings map_pole_pull (p_pole, 80) x how far the point lies from the middle line toward the edge
-- (0 to 1), raised to the eighth power. Halfway to the edge that is 80 x 0.5^8 = 0.3; nine tenths of the way it is
-- 80 x 0.9^8 = 34. p_y = the row of the point on a spread of points p_cell squares apart; p_down = squares down the
-- whole world (the battle grid of rpg_map_ladder), so the spread has p_down / p_cell rows. Written as one expression
-- so it folds into the query that calls it.
SELECT p_pole * (((abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1) * abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1))
                  * (abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1) * abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1)))
                 * ((abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1) * abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1))
                  * (abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1) * abs(2 * (p_y + 0.5::double precision) / (p_down::double precision / p_cell) - 1))));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_heights_on(p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How high the ground stands at the center of every cell in a block of an even spread of points p_cell squares apart,
-- with the layers down to grid p_deep whose points are at least p_cell squares apart (rpg_map_rolls_on; a grid of
-- the ladder has no finer layers than its own cell, so on its own cells it reads every layer down to it). Land where
-- the height is at or above the sea level (rpg_settings map_sea_level, 14.6), sea below it. Worked out when asked and
-- never stored. The height is the height rolls (part 0) less the pull toward the sea at the far north and south
-- (rpg_map_pole_pull), so no land is cut off by the top or bottom edge of the map. rpg_map_heights is this read on
-- the cells of one grid; the ground (rpg_map_nature) reads the same height in its own pass.
SELECT b.x, b.y, b.value - public.rpg_map_pole_pull(b.y, p_cell, c.pole, c.down)
  FROM public.rpg_map_rolls_on(0, 1, p_cell, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) b
 CROSS JOIN (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_pole_pull')::double precision AS pole,
                    (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 7) AS down) c;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_nature(p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground the land itself makes (step 9, 2026-10-04): sea, the kind of unnamed ground, its cover and its climate,
-- at the center of every cell in a block of an even spread of points p_cell squares apart, read with the layers down
-- to grid p_deep whose points are at least p_cell squares apart (finer layers would not show between the points).
-- The one home of the ground of the land; places, rivers and lakes, towns and roads are laid over it by rpg_map_cells.
-- On the cells of one grid (p_deep = the grid, p_cell = its cell) it reads what rpg_map_cells read before step 9; the
-- battle grid reads it so, at every square. Every coarser grid reads it at 3 x 3 points in each of its cells, from
-- the grid under it, and takes what most of them hold (rpg_map_cells).
-- Read in two passes of rpg_map_rolls_set (step 9b, 2026-10-05: one pass for all the rolls a point needs instead of
-- one call a part; the world view fell from about 7 s to about 4): first the height of every point, then, on the
-- points that are land, the kind, the cover grids, warmth and wetness together. The sea is most of the world, and
-- has no kind, cover or climate to read.
-- kind, in this order:
--   sea        its height (the height rolls, part 0, less rpg_map_pole_pull; the same height as rpg_map_heights_on)
--              is below the sea level.
--   mountains  its ground roll (part 1) is within map_mountain_band (6.1) of the middle: mountains run in chains
--              along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- Then the cover (rpg_map_cover): every grid from the Country grid (map_cover_from, 3) down to the District grid
-- (map_cover_to, 6) that p_deep reaches adds its own scatter of woods, clearings and rough ground, read from the
-- three layers of cover rolls of that grid (part 3), coarsest grid first. The World and Continent grids have no cover.
-- Then the climate (rpg_map_climate, Peter 2026-10-03): snow and ice, tundra, pine forest, desert, grassy plains,
-- jungle and swamp. Warmth runs from 100 at the equator to 0 at the poles, moved by map_warmth_share of the warmth
-- rolls (part 4); wetness is the wetness rolls (part 5) moved by map_wet_band with the latitude. Both rolls are read
-- only from the layers whose points are at least map_climate_fine squares apart (one Continent cell), so a spot has
-- the same climate at every zoom; swamp also needs low ground. height = the height of the point.
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_wood')::double precision AS wood,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_rough')::double precision AS rough,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_clear')::double precision AS clear,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_from')::integer AS cover_from,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_to')::integer AS cover_to,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_climate_fine')::integer AS climate_fine,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_warmth_share')::double precision AS warmth_share,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wet_band')::double precision AS wet_band,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_ice_warmth')::double precision AS ice,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_tundra_warmth')::double precision AS tundra,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cold_warmth')::double precision AS cold,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hot_warmth')::double precision AS hot,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_desert_wet')::double precision AS desert,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_plains_wet')::double precision AS plains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_jungle_wet')::double precision AS jungle,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_taiga_wet')::double precision AS taiga,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swamp_wet')::double precision AS swamp_wet,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swamp_height')::double precision AS swamp_height,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_pole_pull')::double precision AS pole,
                    (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 7) AS down),
     ck AS MATERIALIZED (
       -- The grids whose cover this read reaches: from map_cover_from down to p_deep, at most map_cover_to.
       SELECT k.level, k.cell FROM cfg CROSS JOIN public.rpg_map_ladder() k
        WHERE k.level BETWEEN cfg.cover_from AND least(p_deep, cfg.cover_to)),
     rd AS MATERIALIZED (
       -- The readings of the second pass, in order: the kind of ground, the cover rolls of each cover grid (each from
       -- its own three layers, 3 x its level - 2 on, down to points one of its cells apart), warmth and wetness.
       SELECT array_agg(q.part ORDER BY q.o, q.level) AS parts, array_agg(q.frst ORDER BY q.o, q.level) AS frsts,
              array_agg(q.fine ORDER BY q.o, q.level) AS fines, count(*) FILTER (WHERE q.part = 3)::integer AS ncov
         FROM (SELECT 1 AS o, 0 AS level, 1 AS part, 1 AS frst, p_cell AS fine
               UNION ALL
               SELECT 2, ck.level, 3, 3 * ck.level - 2, greatest(ck.cell, p_cell) FROM ck
               UNION ALL
               SELECT 3, 0, 4, 1, greatest(cfg.climate_fine, p_cell) FROM cfg
               UNION ALL
               SELECT 4, 0, 5, 1, greatest(cfg.climate_fine, p_cell) FROM cfg) q),
     h AS MATERIALIZED (
       -- the first pass: the height of every point
       SELECT r.x, r.y, r.vals[1] - public.rpg_map_pole_pull(r.y, p_cell, cfg.pole, cfg.down) AS height
         FROM cfg CROSS JOIN public.rpg_map_rolls_set(ARRAY[0], ARRAY[1], ARRAY[p_cell], p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) r),
     ld AS MATERIALIZED (
       -- the points that are land, numbered across the block row by row from 0 (none: an empty list, so the second
       -- pass reads nothing)
       SELECT coalesce(array_agg((h.y - p_y0) * p_cols + (h.x - p_x0)), '{}'::integer[]) AS at
         FROM h CROSS JOIN cfg WHERE h.height >= cfg.sea),
     g AS MATERIALIZED (
       -- the second pass: the kind, the cover, warmth and wetness of every land point
       SELECT r.x, r.y, r.vals
         FROM rd CROSS JOIN ld
        CROSS JOIN LATERAL public.rpg_map_rolls_set(rd.parts, rd.frsts, rd.fines, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows, ld.at) r)
SELECT h.x, h.y,
       CASE WHEN h.height < cfg.sea THEN 'sea'
            ELSE public.rpg_map_climate(CASE WHEN rd.ncov = 0 THEN b.kind ELSE public.rpg_map_cover(b.kind, g.vals[2:1 + rd.ncov], cfg.wood, cfg.rough, cfg.clear) END,
                                        100 * (1 - e.e) + cfg.warmth_share * g.vals[2 + rd.ncov], g.vals[3 + rd.ncov] + cfg.wet_band * cos(3 * pi() * e.e), h.height - cfg.sea,
                                        cfg.ice, cfg.tundra, cfg.cold, cfg.hot, cfg.desert, cfg.plains, cfg.jungle, cfg.taiga,
                                        cfg.swamp_wet, cfg.swamp_height) END,
       h.height
  FROM h CROSS JOIN cfg CROSS JOIN rd
  LEFT JOIN g ON g.x = h.x AND g.y = h.y
 CROSS JOIN LATERAL (SELECT CASE WHEN abs(g.vals[1]) < cfg.mountains THEN 'mountains'
                                 WHEN abs(g.vals[1]) < cfg.hills THEN 'hills'
                                 WHEN g.vals[1] >= cfg.forest THEN 'forest'
                                 ELSE 'land' END AS kind) b
 -- e = how far the point is from the equator toward a pole, 0 to 1 (points down the whole world: the squares down
 -- the battle grid over p_cell)
 CROSS JOIN LATERAL (SELECT abs(2 * (h.y + 0.5::double precision) / (cfg.down::double precision / p_cell) - 1) AS e) e;
$function$;

REVOKE ALL ON FUNCTION public.rpg_map_rolls_set(integer[], integer[], integer[], integer, integer, integer, integer, integer, integer, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_pole_pull(integer, integer, double precision, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_rolls_set(integer[], integer[], integer[], integer, integer, integer, integer, integer, integer, integer[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_pole_pull(integer, integer, double precision, integer) TO service_role;

