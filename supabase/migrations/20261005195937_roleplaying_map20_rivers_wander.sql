-- Roleplaying world map step 10a (Peter 2026-10-04 13:44: the rivers need to be squiggly lines; his go 2026-10-05 19:26):
-- rivers wander at every scale, the same line at every zoom. Changed in place: rpg_map_rivers (the line swings sideways
-- by a share of every scale from the cell of its grid down to its smallest bend, read from the part 9 rolls in one pass of
-- rpg_map_rolls_set; a grid reads only swings at least two of its cells wide), rpg_map_flow (a river narrower than the
-- cell of the grid is a line on that grid, not water in the cell), rpg_map_buildings (a house stands only with no river or
-- lake under any of it, not only its middle: the test left over from step 8c). Rule card world_map: a sentence on the
-- winding and the worked numbers. No drops, no table changes, no new settings (the share of each scale is
-- map_river_meander_amp over map_river_meander_wave). The page draws each river as one smooth line through the points of its
-- cells (commit with this step).

CREATE OR REPLACE FUNCTION public.rpg_map_rivers(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, dist double precision, px double precision, py double precision, inside boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the rivers run on any block of any grid, worked out when asked and never stored: the one home of a river's
-- line (rpg_map_flow reads it for depth, the Maps tab for the line it draws). Each grid from the Continent grid to the
-- City grid makes its own size of river (k: 2 great rivers, 3 rivers, 4 streams, 5 brooks) along the line where its
-- own three layers of part 7 rolls cross 0.
-- The river then wanders (step 10a, Peter 2026-10-04: rivers are squiggly lines). At every scale from its own grid's
-- cell down to the smallest bend a river of its width makes (map_river_meander_wave, 11 widths: Leopold & Wolman
-- 1960), the line swings sideways by a share of that scale: the layers of part 9 rolls with points less than its cell
-- apart and at least a quarter of that bend apart each push the line by their gap x the share x a roll of unit spread
-- (the roll less 50.5 over 21.4, the spread of one layer blended between its points). The share is the swing of the
-- smallest bend over its wave, map_river_meander_amp 2.7 widths over 11 = 0.245, so the smallest bends swing as they
-- did and the bigger ones swing in the same proportion, the way a river's course wanders at every scale. A grid reads
-- only the layers whose points are at least two of its cells apart (a swing one cell wide cannot be followed from
-- cell to cell: the line is read in each cell from its slope at the middle), so a coarse grid shows the big swings
-- and each finer grid adds the smaller ones, within about half a cell of where the coarser grid drew the line. The push is applied as the field's own slope times the swing, so the 0 line moves sideways
-- by the swing; the slope the line is then read with is that of the pushed field, so the line's own direction is
-- the squiggly one.
-- Per cell and river: dist = squares from the cell's middle to the river's middle line; px, py = the nearest point of
-- that line, from the cell's middle, in cells (east and south positive); inside = that point lies in the cell, so the
-- line runs through it. A grid draws a river as a line through those points.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cls AS MATERIALIZED (
       -- each size of river this grid shows: its grid's cell, its width and the smallest gap of its wandering layers
       SELECT q.k, kl.cell::double precision AS kcell, w.width, greatest(w.width * w.wave / 4, 2 * lad.cell) AS lo
         FROM generate_series(2, 5) AS q(k)
         JOIN public.rpg_map_ladder() kl ON kl.level = q.k
        CROSS JOIN lad
        CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS wave) w
        WHERE q.k <= p_level),
     -- the share of each scale a river swings: the swing of the smallest bend over its wave
     shr AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_meander_amp')::double precision
                    / (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS share),
     wl AS MATERIALIZED (
       -- the wandering layers any river of this grid reads, coarsest first, numbered as the readings below
       SELECT y.n, y.gap::double precision AS gap, row_number() OVER (ORDER BY y.n)::integer AS i
         FROM public.rpg_map_layers() y
        WHERE EXISTS (SELECT 1 FROM cls c WHERE y.gap >= c.lo AND y.gap < c.kcell)),
     f AS MATERIALIZED (
       -- the line's rolls on the block and two cells round it
       SELECT c.k, r.x, r.y, r.value
         FROM cls c CROSS JOIN LATERAL public.rpg_map_rolls(7, 3 * c.k - 2, c.kcell::integer, p_level, p_x0 - 2, p_y0 - 2, p_cols + 4, p_rows + 4) r),
     nb AS (
       SELECT f.k, f.x, f.y, f.value AS v,
              lead(f.value) OVER (PARTITION BY f.k, f.y ORDER BY f.x) AS e, lag(f.value) OVER (PARTITION BY f.k, f.y ORDER BY f.x) AS w,
              lead(f.value) OVER (PARTITION BY f.k, f.x ORDER BY f.y) AS s, lag(f.value) OVER (PARTITION BY f.k, f.x ORDER BY f.y) AS n
         FROM f),
     g AS MATERIALIZED (
       -- the roll and how fast it changes east and south, on the block and one cell round it
       SELECT nb.k, nb.x, nb.y, nb.v, (nb.e - nb.w) / 2 AS gx, (nb.s - nb.n) / 2 AS gy
         FROM nb
        WHERE nb.x BETWEEN p_x0 - 1 AND p_x0 + p_cols AND nb.y BETWEEN p_y0 - 1 AND p_y0 + p_rows),
     wr AS MATERIALIZED (
       -- the wandering rolls, every layer in one pass (rpg_map_rolls_set), on the block and one cell round it
       SELECT r.x, r.y, r.vals
         FROM (SELECT array_agg(9 ORDER BY wl.i) AS parts, array_agg(wl.n ORDER BY wl.i) AS firsts, array_agg(wl.gap::integer ORDER BY wl.i) AS fines
                 FROM wl HAVING count(*) > 0) a
        CROSS JOIN LATERAL public.rpg_map_rolls_set(a.parts, a.firsts, a.fines, p_level, (SELECT lad.cell::integer FROM lad), p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) r),
     sw AS MATERIALIZED (
       -- the swing of each size of river at each cell, in squares: the sum over its layers of gap x share x the roll of unit spread
       SELECT c.k, wr.x, wr.y, sum(wl.gap * shr.share * wr.vals[wl.i] / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))) AS swing
         FROM cls c CROSS JOIN shr JOIN wl ON wl.gap >= c.lo AND wl.gap < c.kcell CROSS JOIN wr
        GROUP BY c.k, wr.x, wr.y),
     sh AS MATERIALIZED (
       -- the field pushed sideways by the swing: v + how fast v changes x the swing in cells, so the 0 line moves by the swing
       SELECT g.k, g.x, g.y, g.v + sqrt(g.gx * g.gx + g.gy * g.gy) / lad.cell * coalesce(sw.swing, 0) AS v
         FROM g CROSS JOIN lad
         LEFT JOIN sw ON sw.k = g.k AND sw.x = g.x AND sw.y = g.y),
     nb2 AS (
       SELECT sh.k, sh.x, sh.y, sh.v,
              lead(sh.v) OVER (PARTITION BY sh.k, sh.y ORDER BY sh.x) AS e, lag(sh.v) OVER (PARTITION BY sh.k, sh.y ORDER BY sh.x) AS w,
              lead(sh.v) OVER (PARTITION BY sh.k, sh.x ORDER BY sh.y) AS s, lag(sh.v) OVER (PARTITION BY sh.k, sh.x ORDER BY sh.y) AS n
         FROM sh),
     g2 AS (
       -- the pushed field and how fast it changes, per cell of the block
       SELECT nb2.k, nb2.x, nb2.y, nb2.v, (nb2.e - nb2.w) / 2 AS gx, (nb2.s - nb2.n) / 2 AS gy, lad.cell
         FROM nb2 CROSS JOIN lad
        WHERE nb2.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND nb2.y BETWEEN p_y0 AND p_y0 + p_rows - 1),
     o AS (SELECT g2.*, greatest(sqrt(g2.gx * g2.gx + g2.gy * g2.gy), 1e-9) AS gl FROM g2)
SELECT o.x, o.y, o.k, abs(o.v) / o.gl * o.cell, -o.v * o.gx / (o.gl * o.gl), -o.v * o.gy / (o.gl * o.gl),
       abs(o.v * o.gx / (o.gl * o.gl)) <= 0.5 AND abs(o.v * o.gy / (o.gl * o.gl)) <= 0.5
  FROM o;
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
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the spread of a field read from three layers counting 1, 1 and 0.6 (see rpg_map_hard for the sum)
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0) * 2.36) AS s),
     rv0 AS (
       SELECT r.x, r.y,
              CASE WHEN r.dist < w.width / 2 AND w.width >= lad.cell THEN w.deep * (1 - power(2 * r.dist / w.width, 2)) ELSE 0 END AS depth,
              CASE WHEN r.inside THEN r.k END AS line, w.deep, w.flow
         FROM public.rpg_map_rivers(p_level, p_x0, p_y0, p_cols, p_rows) r CROSS JOIN lad
        CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_width')::double precision AS width,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_depth')::double precision AS deep,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_current')::double precision AS flow) w),
     rv AS (SELECT rv0.x, rv0.y, rv0.depth, rv0.line,
                   CASE WHEN rv0.depth > 0 THEN rv0.flow * power(rv0.depth / rv0.deep, 2.0 / 3) ELSE 0 END AS current
              FROM rv0),
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
-- lane still has a street through it.
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
        -- every road that crosses it (rpg_map_roads over the whole settlement), in a steady order; each one's line: the
        -- way along it (u) and across it (n), where it passes the middle (t0, along it from a), the half width of its
        -- street, and how far along it houses may stand (lo to hi): the road itself, and for the one road at a middle no
        -- other road reaches, on through the middle to the far side
        WITH rl AS MATERIALIZED (
               SELECT r.class, r.ax, r.ay, r.bx, r.by, row_number() OVER (ORDER BY r.class, r.a, r.b, r.ax, r.ay) AS k
                 FROM public.rpg_map_roads(7, floor(t.mx - t.fx)::integer, floor(t.my - t.fy)::integer,
                                           (ceil(2 * t.fx) + 2)::integer, (ceil(2 * t.fy) + 2)::integer, 7, NULL, 0) r),
             ln AS MATERIALIZED (
               SELECT rl.k, rl.class, rl.ax, rl.ay, d.len, d.ux, d.uy, -d.uy AS nx, d.ux AS ny,
                      (t.mx - rl.ax) * d.ux + (t.my - rl.ay) * d.uy AS t0,
                      CASE rl.class WHEN 1 THEN g.w1 WHEN 2 THEN g.w2 ELSE g.w3 END / 2 AS half,
                      sqrt(power(rl.ax - t.mx, 2) + power(rl.ay - t.my, 2)) < 1 AS at_a,
                      sqrt(power(rl.bx - t.mx, 2) + power(rl.by - t.my, 2)) < 1 AS at_b
                 FROM rl
                CROSS JOIN LATERAL (SELECT sqrt(power(rl.bx - rl.ax, 2) + power(rl.by - rl.ay, 2)) AS len) l0
                CROSS JOIN LATERAL (SELECT l0.len, (rl.bx - rl.ax) / l0.len AS ux, (rl.by - rl.ay) / l0.len AS uy) d
                WHERE l0.len > 0),
             lr AS MATERIALIZED (
               SELECT ln.*,
                      CASE WHEN ln.at_a AND m.n = 1 THEN -greatest(t.fx, t.fy) ELSE 0 END AS lo,
                      CASE WHEN ln.at_b AND m.n = 1 THEN ln.len + greatest(t.fx, t.fy) ELSE ln.len END AS hi
                 FROM ln CROSS JOIN (SELECT count(*) FILTER (WHERE q.at_a OR q.at_b) AS n FROM ln q) m),
             -- how much street runs through it: every line, measured a square at a time where it lies on the
             -- settlement's ground (a card's plain oval for this sum)
             sl AS (
               SELECT count(*) AS len
                 FROM lr
                CROSS JOIN LATERAL (SELECT abs((t.mx - lr.ax) * lr.nx + (t.my - lr.ay) * lr.ny) AS d, greatest(t.fx, t.fy) AS far) q
                CROSS JOIN LATERAL (SELECT greatest(lr.lo, lr.t0 - sqrt(greatest(q.far * q.far - q.d * q.d, 0))) AS ts,
                                           least(lr.hi, lr.t0 + sqrt(greatest(q.far * q.far - q.d * q.d, 0))) AS te) e
                CROSS JOIN LATERAL generate_series(0, greatest(floor(e.te - e.ts)::integer - 1, -1)) AS i
                CROSS JOIN LATERAL (SELECT lr.ax + lr.ux * (e.ts + i + 0.5) AS x, lr.ay + lr.uy * (e.ts + i + 0.5) AS y) p
                WHERE CASE WHEN t.card IS NULL
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
                                  'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('k', lr.k, 'class', lr.class, 'ax', lr.ax, 'ay', lr.ay, 'len', lr.len,
                                                                                         'ux', lr.ux, 'uy', lr.uy, 'nx', lr.nx, 'ny', lr.ny, 't0', lr.t0,
                                                                                         'half', lr.half, 'lo', lr.lo, 'hi', lr.hi) ORDER BY lr.k)
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
                       AS l(k integer, class integer, ax double precision, ay double precision, len double precision, ux double precision, uy double precision,
                            nx double precision, ny double precision, t0 double precision, half double precision, lo double precision, hi double precision)),
           -- the plots of each line near the box (three reaches round the block): its corners measured along and across
           pr AS MATERIALIZED (
             SELECT lr.*, q.tmin, q.tmax
               FROM lr
              CROSS JOIN LATERAL (SELECT min((c.x - lr.ax) * lr.ux + (c.y - lr.ay) * lr.uy) AS tmin, max((c.x - lr.ax) * lr.ux + (c.y - lr.ay) * lr.uy) AS tmax,
                                         min((c.x - lr.ax) * lr.nx + (c.y - lr.ay) * lr.ny) AS smin, max((c.x - lr.ax) * lr.nx + (c.y - lr.ay) * lr.ny) AS smax
                                    FROM (VALUES (p_x0 - 3 * g.r, p_y0 - 3 * g.r), (p_x0 + p_cols + 3 * g.r, p_y0 - 3 * g.r),
                                                 (p_x0 - 3 * g.r, p_y0 + p_rows + 3 * g.r), (p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r)) AS c(x, y)) q
              -- a house stands at most a street, a setback and a house's length from its line
              WHERE lr.f > 0
                AND q.smin <= lr.half + (g.setback_hi + g.vbays_hi * g.bay) / g.sq + g.r
                AND q.smax >= -(lr.half + (g.setback_hi + g.vbays_hi * g.bay) / g.sq + g.r)),
           pl AS MATERIALIZED (
             SELECT pr.town, pr.kind, pr.k, pr.class, pr.ax, pr.ay, pr.ux, pr.uy, pr.nx, pr.ny, pr.half, pr.f, j,
                    pr.t0 + (j + 0.5) * pr.f AS tm, s.side, pr.t0 + (j + 0.5) * pr.f < 0 OR pr.t0 + (j + 0.5) * pr.f > pr.len AS cont
               FROM pr
              CROSS JOIN LATERAL generate_series(greatest(ceil((pr.lo - pr.t0) / pr.f - 1e-6), floor((pr.tmin - pr.t0) / pr.f) - 1)::integer,
                                                 least(floor((pr.hi - pr.t0) / pr.f + 1e-6) - 1, ceil((pr.tmax - pr.t0) / pr.f) + 1)::integer) AS j
              CROSS JOIN (VALUES (-1), (1)) AS s(side)),
           -- each plot's own rolls (u1 to u9, 0 to 1) at the square in its middle on the road's line
           pu AS MATERIALIZED (
             SELECT pl.*, round(pl.ax + pl.ux * pl.tm)::integer AS px, round(pl.ay + pl.uy * pl.tm)::integer AS py,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + CASE WHEN pl.side > 0 THEN 10 ELSE 0 END + n,
                                                           round(pl.ax + pl.ux * pl.tm)::integer, round(pl.ay + pl.uy * pl.tm)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u
               FROM pl),
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
                    hs.ax + hs.ux * (hs.tm + hs.off / g.sq) + hs.nx * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cx,
                    hs.ay + hs.uy * (hs.tm + hs.off / g.sq) + hs.ny * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cy,
                    CASE WHEN hs.along >= hs.deep THEN hs.ux ELSE hs.nx END AS rx, CASE WHEN hs.along >= hs.deep THEN hs.uy ELSE hs.ny END AS ry,
                    greatest(hs.along, hs.deep) / 2 / g.sq AS hl, least(hs.along, hs.deep) / 2 / g.sq AS hw,
                    hs.storeys * hs.storey AS eaves, hs.pitch, hs.storeys,
                    CASE WHEN hs.kind = 'village' THEN 'thatch' ELSE 'tile' END AS roof
               FROM hs),
           -- the houses in that box that keep clear of every road and street of their settlement, each with its place
           -- in the order: bigger road first, then the road counted first, its own road before the street it runs on as,
           -- then the plot nearer the middle
           cl AS MATERIALIZED (
             SELECT hc.*, row_number() OVER (PARTITION BY hc.town ORDER BY hc.class, hc.k, hc.cont, abs(hc.j), hc.j, hc.side) AS n
               FROM hc
              WHERE hc.cx BETWEEN p_x0 - 3 * g.r AND p_x0 + p_cols + 3 * g.r AND hc.cy BETWEEN p_y0 - 3 * g.r AND p_y0 + p_rows + 3 * g.r
                AND NOT EXISTS (
                      SELECT 1 FROM lr
                       CROSS JOIN LATERAL (SELECT lr.ax + lr.ux * lr.lo - hc.cx AS x0, lr.ay + lr.uy * lr.lo - hc.cy AS y0,
                                                  lr.ax + lr.ux * lr.hi - hc.cx AS x1, lr.ay + lr.uy * lr.hi - hc.cy AS y1) e
                       WHERE lr.town = hc.town
                         AND public.rpg_seg_box(e.x0 * hc.rx + e.y0 * hc.ry, e.y0 * hc.rx - e.x0 * hc.ry, e.x1 * hc.rx + e.y1 * hc.ry, e.y1 * hc.rx - e.x1 * hc.ry,
                                                -(hc.hl + lr.half - 0.01), -(hc.hw + lr.half - 0.01), hc.hl + lr.half - 0.01, hc.hw + lr.half - 0.01)))
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

UPDATE public.rpg_rules SET body = replace(body,
'lakes and ponds cover about 4 in 100 of the land.',
'lakes and ponds cover about 4 in 100 of the land. Rivers wind: at every scale, from the smallest bends a river of its width makes (11 widths long) up to the cells of its own grid, the line swings sideways by about a quarter of that scale, so a river wanders at every zoom and the zoomed-in river lies where the zoomed-out one was drawn. A river narrower than a cell is drawn as a line through that cell; it fills cells only where it is at least as wide as they are.
*A 60 m river swings about 2 miles either way over its biggest bends, 7 miles long, and about 160 m over its smallest, 660 m long.*'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('Rivers wind: at every scale' IN body) = 0;

