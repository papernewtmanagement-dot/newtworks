-- Step 7a (Peter 2026-10-03 17:28, 21:45, 22:05, 23:12): rivers and lakes on the world map. Depth sets the time a
-- square of water adds (his 22:05 anchors: a trickle +10%, a stream +25%, a ford +50%, waist-deep +150%; deeper is
-- swimming), deeper is drawn darker, and water too deep to wade stops a walk until swimming comes (7b).

-- River sizes from hydraulic geometry (Leopold & Maddock 1953: width grows with flow, rivers run 10 to 50 times wider
-- than deep); lakes cover about 3.7 in 100 of the land (Verpoorter et al. 2014). A square is 1.118 m.
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_river_2_width', 358::numeric, 'Great rivers (lines from the Continent grid rolls): width in squares, 400 m'),
               ('map_river_2_depth', 8, 'Great rivers: depth in the middle, metres'),
               ('map_river_3_width', 54, 'Rivers (lines from the Country grid rolls): width in squares, 60 m'),
               ('map_river_3_depth', 3, 'Rivers: depth in the middle, metres'),
               ('map_river_4_width', 9, 'Streams (lines from the Region grid rolls): width in squares, 10 m'),
               ('map_river_4_depth', 0.8, 'Streams: depth in the middle, metres'),
               ('map_river_5_width', 2, 'Brooks (lines from the City grid rolls): width in squares, 2 m'),
               ('map_river_5_depth', 0.25, 'Brooks: depth in the middle, metres'),
               ('map_lake_3_share', 0.015, 'Big lakes (blobs from the Country grid rolls): share of the land they cover'),
               ('map_lake_3_depth', 30, 'Big lakes: deepest, metres'),
               ('map_lake_4_share', 0.012, 'Lakes (blobs from the Region grid rolls): share of the land they cover'),
               ('map_lake_4_depth', 10, 'Lakes: deepest, metres'),
               ('map_lake_5_share', 0.01, 'Ponds (blobs from the City grid rolls): share of the land they cover'),
               ('map_lake_5_depth', 2, 'Ponds: deepest, metres'),
               ('map_lake_slope', 0.05, 'How fast a lake bed drops from its shore: metres of depth a metre out (1 in 20)'),
               ('map_square_m', 1.118, 'One square in metres (the world is the size of the Earth, 12^7 squares round)'),
               ('map_wade_trickle', 10, 'Water: percent of time a square adds at a trickle (no depth to speak of)'),
               ('map_wade_stream_depth', 0.25, 'Water: depth of a stream, metres (shin-deep)'),
               ('map_wade_stream', 25, 'Water: percent of time a square adds at a stream'),
               ('map_wade_ford_depth', 0.5, 'Water: depth of a ford, metres (knee-deep)'),
               ('map_wade_ford', 50, 'Water: percent of time a square adds at a ford'),
               ('map_wade_waist_depth', 1, 'Water: waist-deep, metres'),
               ('map_wade_waist', 150, 'Water: percent of time a square adds waist-deep'),
               ('map_swim_depth', 1.2, 'Water deeper than this (metres, chest-deep) cannot be waded: it is swum')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_water(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, depth double precision, line integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rivers and lakes on any block of any grid, worked out when asked and never stored: the one home of where water lies
-- on land (Peter 2026-10-03 17:28: rivers and lakes). rpg_map_cells reads it to make a dry cell water.
-- Rivers run along the lines where a smooth field of rolls crosses 0 (part 7, the same way mountains run along the
-- middle of the ground rolls). Each grid from the Continent grid to the City grid makes its own size, from its own
-- three layers of rolls: great rivers 400 m wide (Continent), rivers 60 m (Country), streams 10 m (Region), brooks 2 m
-- (City), each map_river_<grid>_width squares wide and map_river_<grid>_depth deep in the middle, shallower toward the
-- banks (depth = middle x (1 - (2 x distance / width)^2)). The distance from the line is the roll over how fast the
-- roll changes from cell to cell, read from the cells round it. Lakes sit where another field (part 8) of a grid's
-- rolls rises above the height that leaves map_lake_<grid>_share of the land under water (big lakes, lakes, ponds:
-- 1.5, 1.2 and 1 in 100, 3.7 in all); their bed drops map_lake_slope (1 in 20) from the shore, down to
-- map_lake_<grid>_depth. A grid shows only the water its own cells or coarser ones make: a brook is not on the
-- Region grid. depth = metres of water at the middle of the cell (the deepest of what lies there; 0 for none). line =
-- the biggest river whose middle line passes within half a cell of the cell's middle (2 a great river, 3 a river, 4 a
-- stream, 5 a brook): how a grid too coarse to hold a river as cells draws it as a line; less than 0 (-2 to -5) when
-- the line only cuts a corner of the cell (rpg_map_walk looks closer there too); 0 none.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the spread of a field read from three layers counting 1, 1 and 0.6 (see rpg_map_hard for the sum)
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0) * 2.36) AS s),
     cls AS MATERIALIZED (
       SELECT q.part, q.k, k.cell::double precision AS kcell,
              (SELECT st.value FROM st WHERE st.key = q.pre || q.k || q.a)::double precision AS a,
              (SELECT st.value FROM st WHERE st.key = q.pre || q.k || '_depth')::double precision AS deep
         FROM (VALUES (7, 2, 'map_river_', '_width'), (7, 3, 'map_river_', '_width'), (7, 4, 'map_river_', '_width'), (7, 5, 'map_river_', '_width'),
                      (8, 3, 'map_lake_', '_share'), (8, 4, 'map_lake_', '_share'), (8, 5, 'map_lake_', '_share')) AS q(part, k, pre, a)
         JOIN public.rpg_map_ladder() k ON k.level = q.k
        WHERE q.k <= p_level),
     f AS MATERIALIZED (
       -- each field on the block and one cell round it
       SELECT c.part, c.k, r.x, r.y, r.value
         FROM cls c CROSS JOIN LATERAL public.rpg_map_rolls(c.part, 3 * c.k - 2, c.kcell::integer, p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) r),
     nb AS (
       -- each cell with the rolls of the cells east, west, south and north of it
       SELECT f.part, f.k, f.x, f.y, f.value AS v,
              lead(f.value) OVER (PARTITION BY f.part, f.k, f.y ORDER BY f.x) AS e, lag(f.value) OVER (PARTITION BY f.part, f.k, f.y ORDER BY f.x) AS w,
              lead(f.value) OVER (PARTITION BY f.part, f.k, f.x ORDER BY f.y) AS s, lag(f.value) OVER (PARTITION BY f.part, f.k, f.x ORDER BY f.y) AS n
         FROM f),
     g AS MATERIALIZED (
       -- at every cell of the block: the roll and how fast it changes, per cell of this grid
       SELECT nb.part, nb.k, nb.x, nb.y, nb.v, sqrt(power((nb.e - nb.w) / 2, 2) + power((nb.s - nb.n) / 2, 2)) AS slope
         FROM nb
        WHERE nb.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND nb.y BETWEEN p_y0 AND p_y0 + p_rows - 1),
     w AS (
       SELECT g.x, g.y, g.part, g.k,
              -- rivers: squares from the middle line; lakes: squares in from the shore
              CASE WHEN g.part = 7 THEN abs(g.v) / greatest(g.slope, 1e-9) * lad.cell
                   ELSE (g.v - z.t) / greatest(g.slope, 1e-9) * lad.cell END AS d,
              c.a, c.deep, z.t, lad.cell
         FROM g JOIN cls c ON c.part = g.part AND c.k = g.k
        CROSS JOIN lad CROSS JOIN sd
        -- a lake: the height that leaves its share above it, by the normal curve (Abramowitz and Stegun 26.2.23)
        CROSS JOIN LATERAL (SELECT CASE WHEN g.part = 8
                                        THEN sd.s * (sqrt(-2 * ln(c.a)) - (2.515517 + 0.802853 * sqrt(-2 * ln(c.a)) + 0.010328 * (-2 * ln(c.a)))
                                                                         / (1 + 1.432788 * sqrt(-2 * ln(c.a)) + 0.189269 * (-2 * ln(c.a)) + 0.001308 * power(sqrt(-2 * ln(c.a)), 3))) END AS t) z
),
     dep AS (
       SELECT w.x, w.y,
              CASE WHEN w.part = 7 AND w.d < w.a / 2 THEN w.deep * (1 - power(2 * w.d / w.a, 2))
                   WHEN w.part = 8 AND w.d > 0 THEN least(w.deep, w.d * (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision
                                                                     * (SELECT st.value FROM st WHERE st.key = 'map_lake_slope')::double precision)
                   ELSE 0 END AS depth,
              CASE WHEN w.part = 7 AND w.d <= w.cell / 2 THEN w.k WHEN w.part = 7 AND w.d <= w.cell * 0.7072 THEN -w.k END AS line
         FROM w)
SELECT b.x, b.y, coalesce(max(dep.depth), 0),
       coalesce(min(dep.line) FILTER (WHERE dep.line > 0), max(dep.line) FILTER (WHERE dep.line < 0), 0)
  FROM (SELECT gx AS x, gy AS y FROM generate_series(p_x0, p_x0 + p_cols - 1) gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) gy) b
  LEFT JOIN dep ON dep.x = b.x AND dep.y = b.y
 GROUP BY b.x, b.y;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_wade_pct(p_depth double precision)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The percent of time a square of water adds to wade it, by its depth in metres: the one home of that sum (Peter
-- 2026-10-03 22:05: a trickle +10%, a stream +25%, a ford +50%, waist-deep +150%). Straight lines between his points:
-- no depth to speak of map_wade_trickle (10), map_wade_stream_depth 0.25 m map_wade_stream (25), map_wade_ford_depth
-- 0.5 m map_wade_ford (50), map_wade_waist_depth 1 m map_wade_waist (150), and on at the same rise past the waist up
-- to map_swim_depth (1.2 m: 190). Nothing deeper: that water is swum. A knee-deep ford, 0.5 m: 50.
WITH st AS (SELECT s.key, s.value::double precision AS v FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     p AS (SELECT (SELECT v FROM st WHERE key = 'map_wade_trickle') AS p0,
                  (SELECT v FROM st WHERE key = 'map_wade_stream_depth') AS d1, (SELECT v FROM st WHERE key = 'map_wade_stream') AS p1,
                  (SELECT v FROM st WHERE key = 'map_wade_ford_depth') AS d2, (SELECT v FROM st WHERE key = 'map_wade_ford') AS p2,
                  (SELECT v FROM st WHERE key = 'map_wade_waist_depth') AS d3, (SELECT v FROM st WHERE key = 'map_wade_waist') AS p3,
                  (SELECT v FROM st WHERE key = 'map_swim_depth') AS swim)
SELECT CASE WHEN p_depth IS NULL OR p_depth >= p.swim THEN NULL
            WHEN p_depth <= p.d1 THEN round(p.p0 + (p.p1 - p.p0) * greatest(p_depth, 0) / p.d1)
            WHEN p_depth <= p.d2 THEN round(p.p1 + (p.p2 - p.p1) * (p_depth - p.d1) / (p.d2 - p.d1))
            WHEN p_depth <= p.d3 THEN round(p.p2 + (p.p3 - p.p2) * (p_depth - p.d2) / (p.d3 - p.d2))
            ELSE round(p.p3 + (p.p3 - p.p2) * (p_depth - p.d3) / (p.d3 - p.d2)) END::integer
  FROM p;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; rivers and
-- lakes), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
-- detail; the page reads the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent
-- of time a square of it adds to cross it (the most is the same key with _high; rpg_map_band; water goes by its depth,
-- rpg_map_wade_pct; the sea and deep water = no walking in), and whether it is forest (it has trees: it burns and
-- hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', 'map_land_penalty', false),
               (3, 'plains', 'Grassy plains', 'g', 'map_plains_penalty', false),
               (4, 'forest', 'Forest', 't', 'map_forest_penalty', true),
               (5, 'pine', 'Pine forest', 'p', 'map_pine_penalty', true),
               (6, 'jungle', 'Jungle', 'j', 'map_jungle_penalty', true),
               (7, 'hills', 'Hills', 'h', 'map_hills_penalty', false),
               (8, 'mountains', 'Mountains', 'm', 'map_mountain_penalty', false),
               (9, 'desert', 'Desert', 'd', 'map_desert_penalty', false),
               (10, 'tundra', 'Tundra', 'u', 'map_tundra_penalty', false),
               (11, 'ice', 'Snow and ice', 'i', 'map_ice_penalty', false),
               (12, 'swamp', 'Swamp', 's', 'map_swamp_penalty', false),
               (13, 'water', 'Shallow water', 'w', NULL, false),
               (14, 'deep', 'Deep water', 'k', NULL, false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_band(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(low integer, high integer, thicket integer, share double precision, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The range of a kind of ground, the one home of it (Peter 2026-10-03 22:05, 1B: it must match reality): the least
-- and the most percent of time a square of it adds to cross it, and for forest its thickets. Unnamed ground reads the
-- settings rpg_map_grounds names (forest 20 to 150, thickets 400 for one square in eight); a place reads its card
-- (place_penalty to place_penalty_high), and a place that is forest has thickets too unless its range already reaches
-- them (Bramblemaw's Lair is all thicket, 400). Shallow water runs from a trickle to just short of swimming
-- (rpg_map_wade_pct: 10 to 190); a square of it goes by its depth, not by a roll. thicket = the percent of a thicket,
-- nothing when it has none; share = how many of its squares are thicket (0 when none). The sea, deep water, or a
-- place that only names the land, has no row: nobody walks into them.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     t AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_thicket_penalty')::integer AS pct,
                  (SELECT st.value FROM st WHERE st.key = 'map_thicket_share')::double precision AS share),
     b AS (SELECT c.place_penalty AS low, coalesce(c.place_penalty_high, c.place_penalty) AS high,
                  coalesce(c.place_forest, false) AS forest, coalesce(c.place_forest, false) AS thick
             FROM public.rpg_creatures c
            WHERE p_kind = 'place' AND c.id = p_place AND c.place_penalty IS NOT NULL
           UNION ALL
           SELECT (SELECT st.value FROM st WHERE st.key = g.penalty_key)::integer,
                  (SELECT st.value FROM st WHERE st.key = g.penalty_key || '_high')::integer,
                  g.forest, g.kind IN ('forest', 'pine')
             FROM public.rpg_map_grounds() g
            WHERE g.kind = p_kind AND g.penalty_key IS NOT NULL
           UNION ALL
           SELECT public.rpg_map_wade_pct(0), public.rpg_map_wade_pct((SELECT st.value FROM st WHERE st.key = 'map_swim_depth')::double precision - 0.001), false, false
            WHERE p_kind = 'water')
SELECT b.low, b.high,
       CASE WHEN b.thick AND b.high < t.pct THEN t.pct END,
       CASE WHEN b.thick AND b.high < t.pct THEN t.share ELSE 0 END,
       b.forest
  FROM b CROSS JOIN t;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_band_text(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A ground in words, the same for a place card and for unnamed ground: forest or not (a place only; the name of an
-- unnamed ground says it), its range, its thickets and its average square. Forest reads "+20% to +150% time a square,
-- thickets +400%, about +124% on average". Shallow water reads its depths ("+10% at a trickle, +25% a stream, +50% a
-- ford, +150% waist-deep"), deep water that it is swum; a place that only names the land reads nothing.
SELECT CASE WHEN p_kind = 'water'
            THEN '+' || public.rpg_map_wade_pct(0) || '% at a trickle, +' || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_stream_depth'))
                 || '% a stream, +' || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_ford_depth')) || '% a ford, +'
                 || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_waist_depth')) || '% waist-deep'
            WHEN p_kind = 'deep' THEN 'deeper than ' || trim_scale((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth')::numeric) || ' m, so it is swum, not waded'
            ELSE (SELECT concat_ws(' · ', CASE WHEN p_kind = 'place' AND b.forest THEN 'forest' END,
                                   CASE WHEN b.low = b.high THEN '+' || b.low || '% time a square'
                                        ELSE '+' || b.low || '% to +' || b.high || '% time a square' END
                                   || CASE WHEN b.thicket IS NOT NULL THEN ', thickets +' || b.thicket || '%' ELSE '' END
                                   || CASE WHEN b.low <> b.high THEN ', about +' || (SELECT g.penalty FROM public.rpg_map_ground(p_kind, p_place) g) || '% on average' ELSE '' END)
                    FROM public.rpg_map_band(p_kind, p_place) b) END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A block of cells of any grid with what each costs to cross: the cell as rpg_map_cells gives it, how hard it is inside
-- its ground (rpg_map_hard; nothing on a grid coarser than the City grid), and from those the percent of time it adds
-- (rpg_map_pct on its ground's range, rpg_map_band, read once a ground) and whether it is forest. Shallow water goes by
-- its depth instead (rpg_map_water, rpg_map_wade_pct), and its hard is how deep it is, up to swimming depth (deep
-- water 1), so deeper water is drawn darker. penalty = that percent; nothing for the sea and deep water. The one way a
-- block of the map is read with its costs: fight boards (rpg_fight_squares) and the Maps tab (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the water only when the block holds some
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind IN ('water', 'deep'))),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1) ELSE h.hard END
  FROM c
 CROSS JOIN sw
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
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
--   sea        its height (rpg_map_heights) is below the sea level. The sea stays sea under every place.
--   water      rivers and lakes on dry land (rpg_map_water): deep where the middle of the cell is deeper than
--   deep       map_swim_depth (1.2 m, chest-deep: it is swum), else water (it is waded). Water lies over places
--              and every ground; the cell keeps its place (place_id) so a river in the Old Forest is in it.
--   place      its center lies inside a place card with ground of its own (a movement penalty), by the natural
--              edge of that place (rpg_map_within); place_id = the smallest such card. A place fills cells of a
--              grid when its oval covers the center of the cell its own center falls in; only places that fill
--              are ground.
--   mountains  unnamed land whose ground roll (rpg_map_blend, part 1) is within map_mountain_band (6.1) of the
--              middle: mountains run in chains along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- Then the cover of unnamed land (rpg_map_cover): every grid from the Country grid (map_cover_from, 3) down to the
-- District grid (map_cover_to, 6) that this grid reaches adds its own scatter of woods, clearings and rough ground,
-- read from the three layers of cover rolls of that grid (rpg_map_rolls, part 3), coarsest grid first. What a coarser
-- grid shows stays; each finer grid adds smaller patches. The World and Continent grids have no cover.
-- Then the climate of the spot (rpg_map_climate, Peter 2026-10-03): snow and ice, tundra, pine forest, desert, grassy
-- plains, jungle and swamp. Warmth runs from 100 at the equator to 0 at the poles, moved by map_warmth_share of the
-- warmth rolls (part 4); wetness is the wetness rolls (part 5) moved by map_wet_band with the latitude, wettest at the
-- equator and two thirds of the way to a pole, driest a third of the way and at the poles. Both rolls are read only
-- from the layers whose points are at least map_climate_fine squares apart (one Continent cell, 173 miles), so a
-- spot has the same climate at every zoom from the Continent grid down; swamp also needs low ground, which a finer
-- grid sees in more detail, the way it sees the coast.
-- A place with no movement penalty (a continent, a country) only names the land and never changes a cell.
-- marks = the places with ground that reach into a land cell but are too small or too thin to fill any cell of
-- this grid, smallest first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this
-- grid is about are marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is
-- not marked on a Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, l.down, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_wood')::double precision AS wood,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_rough')::double precision AS rough,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_clear')::double precision AS clear,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_from')::integer AS cover_from,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_to')::integer AS cover_to,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge,
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
     ck AS MATERIALIZED (
       -- The grids whose cover this grid reaches: from map_cover_from down to this grid, at most map_cover_to.
       SELECT k.level, k.cell FROM cfg CROSS JOIN public.rpg_map_ladder() k
        WHERE k.level BETWEEN cfg.cover_from AND least(p_level, cfg.cover_to)),
     cv AS MATERIALIZED (
       -- The cover rolls of each of those grids at every cell of the block, coarsest grid first; each grid reads only
       -- its own three layers (from layer 3 x its level - 2, down to points one of its cells apart).
       SELECT r.x, r.y, array_agg(r.value ORDER BY ck.level) AS rolls
         FROM ck CROSS JOIN LATERAL public.rpg_map_rolls(3, 3 * ck.level - 2, ck.cell, p_level, p_x0, p_y0, p_cols, p_rows) r
        GROUP BY r.x, r.y),
     cl AS MATERIALIZED (
       -- The climate rolls of every cell of the block: warmth (part 4) and wetness (part 5), read only from the layers
       -- whose points are at least map_climate_fine squares apart.
       SELECT t.x, t.y, t.value AS warm, w.value AS wet
         FROM cfg
        CROSS JOIN LATERAL public.rpg_map_rolls(4, 1, cfg.climate_fine, p_level, p_x0, p_y0, p_cols, p_rows) t
         JOIN LATERAL public.rpg_map_rolls(5, 1, cfg.climate_fine, p_level, p_x0, p_y0, p_cols, p_rows) w ON w.x = t.x AND w.y = t.y),
     g AS MATERIALIZED (
       SELECT h.x AS gx, h.y AS gy, h.height >= cfg.sea AS dry, lad.cell, lad.world,
              CASE WHEN h.height < cfg.sea THEN 'sea'
                   ELSE public.rpg_map_climate(CASE WHEN cv.rolls IS NULL THEN b.kind ELSE public.rpg_map_cover(b.kind, cv.rolls, cfg.wood, cfg.rough, cfg.clear) END,
                                               100 * (1 - e.e) + cfg.warmth_share * cl.warm, cl.wet + cfg.wet_band * cos(3 * pi() * e.e), h.height - cfg.sea,
                                               cfg.ice, cfg.tundra, cfg.cold, cfg.hot, cfg.desert, cfg.plains, cfg.jungle, cfg.taiga,
                                               cfg.swamp_wet, cfg.swamp_height) END AS kind
         FROM lad CROSS JOIN cfg
        CROSS JOIN public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h
         JOIN public.rpg_map_blend(1, p_level, p_x0, p_y0, p_cols, p_rows) r ON r.x = h.x AND r.y = h.y
        CROSS JOIN LATERAL (SELECT CASE WHEN abs(r.value) < cfg.mountains THEN 'mountains'
                                        WHEN abs(r.value) < cfg.hills THEN 'hills'
                                        WHEN r.value >= cfg.forest THEN 'forest'
                                        ELSE 'land' END AS kind) b
         LEFT JOIN cv ON cv.x = h.x AND cv.y = h.y
         JOIN cl ON cl.x = h.x AND cl.y = h.y
        -- e = how far the cell is from the equator toward a pole, 0 to 1
        CROSS JOIN LATERAL (SELECT abs(2 * (h.y + 0.5::double precision) / lad.down - 1) AS e) e),
     wt AS MATERIALIZED (
       -- rivers and lakes on the block (rpg_map_water)
       SELECT w.x, w.y, w.depth FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w),
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
            WHEN wt.depth >= cfg.swim THEN 'deep'
            WHEN wt.depth > 0 THEN 'water'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim
 ORDER BY g.gy, g.gx;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_costs on the battle
-- grid: the percent of time each square adds to cross it, and forest; the sea and deep water no entry), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map)
SELECT g.x, g.y,
       CASE WHEN m.kind IN ('sea', 'deep') THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       coalesce(m.forest, false) OR i.forest, i.burning, coalesce(m.kind IN ('sea', 'deep'), false)
  FROM s CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a piece on a square of the world map (counted from 1, as pieces stand), or with no square takes
-- it off. Free, any time, but never onto the sea or a square someone takes up; placing a piece forgets where it was
-- heading. A fight off the map has no board, so there it can only take someone off.
DECLARE v_p record; v_s record; v_who text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
  ELSE
    IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board; meet creatures on a journey'; END IF;
    IF p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
       OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
      RAISE EXCEPTION 'that square is off the map';
    END IF;
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN RAISE EXCEPTION 'that square is sea or deep water'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
    IF v_p.creature_id IS NULL THEN PERFORM public.rpg_map_trail_add(v_p.character_id, p_x, p_y, p_x, p_y); END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
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
-- The walk runs straight (rpg_map_line, ground from rpg_map_route, looked at closer where the sea starts) and stops:
--   at the shore: nobody walks into the sea (2A), nor into water too deep to wade until swimming comes (step 7b); the piece stands on the last dry square before it;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it), stepping back along the walk if it must.
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
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  SELECT l.steps INTO v_steps FROM public.rpg_map_line(v_sx, v_sy, v_gx, v_gy) l;
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
  FOR v_pass IN 1 .. 40 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, v_gx, v_gy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_r.kind = 'water' OR v_r.level < 7 THEN
        SELECT w.depth, w.line INTO v_wd, v_wl
          FROM public.rpg_map_water(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_r.kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep)) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_r.kind, v_r.place_id) b;
      END IF;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (100 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer);
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A)
      IF v_n > 0 THEN
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
      EXIT WHEN v_why = 'meet';
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux)
    SELECT max(ux.k) INTO v_k
      FROM ux CROSS JOIN bb
      JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind NOT IN ('sea', 'deep')
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, v_base / 100.0);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR v_p.day_walk_ticks + v_walk >= v_day;
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea or water too deep to wade is in the way' ELSE 'someone is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_y END,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  -- what the character saw on the way (rpg_map_found reads these stretches)
  IF v_k > 0 THEN PERFORM public.rpg_map_trail_add(v_p.character_id, v_sx + 1, v_sy + 1, v_tx + 1, v_ty + 1); END IF;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk) || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'shore' THEN ' The sea or water too deep to wade stops the walk.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text(v_steps - v_k) || ' to go.' ELSE '' END;
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
-- river, 3 a river, 4 a stream, 5 a brook; rpg_map_water), and the detail carries rivers, one digit a cell (0 none).
-- journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
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

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'x', c.x - v_x0 + 1, 'y', c.y - v_y0 + 1,
           'name', public.rpg_square_name(c.x - v_x0 + 1, c.y - v_y0 + 1),
           'kind', CASE WHEN k.seen THEN c.kind ELSE 'unknown' END, 'place', CASE WHEN k.seen THEN c.place_id END,
           'marks', CASE WHEN k.seen AND cardinality(c.marks) > 0 THEN to_jsonb(c.marks) END,
           'cost', CASE WHEN k.seen THEN c.penalty END,
           'hard', CASE WHEN k.seen AND (c.penalty IS NOT NULL OR c.kind = 'deep') AND c.hard IS NOT NULL THEN least(floor(c.hard * 10), 9)::integer END,
           'river', CASE WHEN k.seen AND rv.line > 0 AND c.kind NOT IN ('water', 'deep', 'sea') THEN rv.line END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || wx.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(wx.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows) c
    LEFT JOIN public.rpg_map_water(v_l.level, v_x0, v_y0, v_cols, v_rows) rv ON rv.x = c.x AND rv.y = c.y
    LEFT JOIN (SELECT DISTINCT w.x, w.y
                 FROM unnest(v_known) AS n(id)
                CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_cols, v_rows) w
                WHERE NOT v_gm) kn ON kn.x = c.x AND kn.y = c.y
   CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
   -- the cell itself counted round the world, for a block that runs past the east or west end
   CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx;

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
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM public.rpg_map_costs(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) c
             LEFT JOIN public.rpg_map_water(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id))
                                            ELSE g.ch END, '' ORDER BY d.x) AS line,
                       string_agg(CASE WHEN d.seen AND (d.penalty IS NOT NULL OR d.kind = 'deep') AND d.hard IS NOT NULL THEN least(floor(d.hard * 10), 9)::integer::text
                                       ELSE '-' END, '' ORDER BY d.x) AS hard,
                       string_agg(CASE WHEN d.seen AND d.line > 0 AND d.kind NOT IN ('water', 'deep', 'sea') THEN d.line::text ELSE '0' END, '' ORDER BY d.x) AS rivers
                  FROM d CROSS JOIN u
                  LEFT JOIN public.rpg_map_grounds() g ON g.kind = d.kind
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'wrap', p_place IS NULL, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y),
                              'hard', CASE WHEN bool_or(ln.hard ~ '[0-9]') THEN jsonb_agg(ln.hard ORDER BY ln.y) END,
                              'rivers', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.rivers ORDER BY ln.y) END,
                              'marks', (SELECT jsonb_object_agg((d.x - v_x0 * v_sub)::text || ',' || (d.y - v_y0 * v_sub)::text, to_jsonb(d.marks))
                                          FROM d WHERE d.seen AND cardinality(d.marks) > 0))
      INTO v_detail
      FROM ln;
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
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- Rule cards: water on the fight board and the world map (step 7a)
UPDATE public.rpg_rules SET body = replace(body,
'mountains +200% to +500%. Where a square sits in its range never changes,',
'mountains +200% to +500%. Water goes by its depth: +10% at a trickle, +25% a shin-deep stream, +50% a knee-deep ford, +150% waist-deep; water deeper than 1.2 m (chest-deep) has to be swum, and until swimming comes nobody steps into it. Where a square sits in its range never changes,'),
       updated_at = now()
 WHERE id = 'ea8b2e3c-e7bb-408a-baf9-5a4e05acab3a' AND position('mountains +200% to +500%. Where a square sits' IN body) > 0;

UPDATE public.rpg_rules SET body = replace(body,
'Nobody walks into the sea. A walk that reaches the water stops on the last dry square.',
'Rivers and lakes run through the land: great rivers 400 m wide and 8 m deep in the middle, rivers 60 m and 3 m, streams 10 m and 0.8 m, brooks 2 m and a quarter of a metre; lakes and ponds cover about 4 in 100 of the land. A square of water adds time by its depth, the same as on a fight board, and deeper water is drawn darker. Water deeper than 1.2 m is swum, not waded; until swimming comes, a walk stops at its edge, so a great river or a river is a wall without a bridge or a boat.
*A knee-deep ford square takes 5 × 1.5 = 7.5 base ticks, 8 ticks at Speed 10. Wading across a 10 m stream, 9 squares, takes about 72 ticks, 12 seconds.*

Nobody walks into the sea or into water too deep to wade. A walk that reaches it stops on the last dry square.'),
       updated_at = now()
 WHERE id = '43307999-7795-4893-beda-b2d1eb70ccac' AND position('Nobody walks into the sea. A walk that reaches the water stops on the last dry square.' IN body) > 0;

