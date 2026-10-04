-- Step 7b (Peter 2026-10-03 22:05, 23:12, 23:51; 2026-10-04 02:37 "Continue"): swimming. Water too deep to wade is
-- swum: a square of it takes as long as swimming does, and the swimmer rolls Swimming against the water's pull again
-- and again while in it; a miss sends them under, and someone under too long who cannot breathe water starts to drown.
-- Gear adds to the swimmer's own roll through Swimming with Gear, a skill built on Swimming.

-- Real numbers. A leisurely swimmer makes about 0.5 m/s (breaststroke, open water) against 1.34 m/s walking, so a
-- square of deep water takes 2.7 times as long: +170%. Rivers flow fastest in the middle, slower toward the banks
-- (speed grows with depth to the 2/3, Manning); mid-channel speeds by size from hydraulic geometry (Leopold & Maddock
-- 1953): great rivers 1.8 m/s, rivers 1.2, streams 0.6, brooks 0.4. Lakes and ponds are still water with small waves,
-- taken as 0.1 m/s. Water flowing as fast as an average swimmer swims (0.7 m/s) is the standard challenge, difficulty
-- 5; water faster than the fastest swimmers (2.1 m/s) cannot be swum at all: it takes a boat. A swimmer in trouble
-- holds their breath about 30 seconds (the instinctive drowning response lasts 20 to 60 seconds, Pia 1974), and goes
-- unconscious about 2 minutes after going under (Szpilman et al., NEJM 2012): 90 seconds past the breath.
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_swim_pct', 170::numeric, 'Swimming: percent of time a square of water too deep to wade adds (about 0.5 m/s swimming against 1.34 m/s walking)'),
               ('map_river_2_current', 1.8, 'Great rivers: how fast the water flows in the middle, m/s (slower toward the banks)'),
               ('map_river_3_current', 1.2, 'Rivers: how fast the water flows in the middle, m/s'),
               ('map_river_4_current', 0.6, 'Streams: how fast the water flows in the middle, m/s'),
               ('map_river_5_current', 0.4, 'Brooks: how fast the water flows in the middle, m/s'),
               ('map_still_current', 0.1, 'Lakes and ponds: still water with small waves, counted as this many m/s of pull'),
               ('map_swim_even_current', 0.7, 'Water pulling as fast as an average swimmer swims (m/s) is difficulty 5 to swim'),
               ('map_swim_too_rough', 2.1, 'Water pulling this fast or faster (m/s, faster than the fastest swimmers) cannot be swum: it takes a boat'),
               ('swim_breath_ticks', 180, 'Swimming: how long someone under water holds their breath while struggling, ticks (30 seconds)'),
               ('swim_drown_ticks', 540, 'Swimming: how long past the breath someone under water lasts before they are down, ticks (90 seconds)')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

-- A card can say its beings breathe water (a fish): they can go under and never drown. Cards made from it inherit it.
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS breathes_water boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.rpg_creatures.breathes_water IS 'Beings made from this card, or from any card made from it, breathe under water: they can go under while swimming and never drown (step 7b).';

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
-- none). line = the biggest river whose line runs through the cell (2 a great river, 3 a river, 4 a stream, 5 a brook;
-- 0 none): a grid too coarse to hold a river as cells still knows it is there (rpg_map_walk looks closer at a deep
-- one). current = how fast the water there pulls, m/s (the fastest of what lies there; 0 on dry land).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the spread of a field read from three layers counting 1, 1 and 0.6 (see rpg_map_hard for the sum)
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0) * 2.36) AS s),
     rv0 AS (
       SELECT r.x, r.y,
              CASE WHEN r.dist < w.width / 2 THEN w.deep * (1 - power(2 * r.dist / w.width, 2)) ELSE 0 END AS depth,
              CASE WHEN r.inside THEN r.k END AS line, w.deep, w.flow
         FROM public.rpg_map_rivers(p_level, p_x0, p_y0, p_cols, p_rows) r
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

CREATE OR REPLACE FUNCTION public.rpg_map_water(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, depth double precision, line integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where water lies on a block of any grid: depth (metres at the middle of each cell) and line (the biggest river whose
-- line runs through it, 2 to 5; 0 none), as rpg_map_flow works them out (the one home of rivers and lakes).
-- rpg_map_cells reads it to make a dry cell water.
SELECT f.x, f.y, f.depth, f.line FROM public.rpg_map_flow(p_level, p_x0, p_y0, p_cols, p_rows) f;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_swim_difficulty(p_current double precision)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The difficulty of a Swimming roll in water pulling p_current m/s: the one home of that sum (step 7b). Water pulling as
-- fast as an average swimmer swims (map_swim_even_current, 0.7 m/s) is the standard challenge (default_difficulty, 5),
-- and it rises in step with the pull: difficulty = 5 x pull / 0.7, one decimal. Still water counts its small waves
-- (map_still_current, 0.1 m/s: difficulty 0.7). Nothing when the water pulls at map_swim_too_rough (2.1 m/s) or more:
-- no swimmer makes headway there, it takes a boat. A river's middle (1.2 m/s): 8.6; a great river's (1.8 m/s): 12.9.
SELECT CASE WHEN coalesce(p_current, 0) >= (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_too_rough')::double precision THEN NULL
            ELSE round((public.rpg_setting('default_difficulty')
                        * greatest(coalesce(p_current, 0), (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_still_current')::double precision)
                        / (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_even_current')::double precision)::numeric, 1) END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_swim(p_x integer, p_y integer)
 RETURNS TABLE(depth double precision, current double precision, difficulty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The water a world square holds when it is too deep to wade (p_x, p_y counted from 1, as pieces stand): its depth in
-- metres, how fast it pulls (m/s) and the difficulty of a Swimming roll there (rpg_map_swim_difficulty; nothing when
-- it is too rough to swim). No row when the square is dry or shallow enough to wade. Read off the battle grid
-- (rpg_map_flow). The middle of a 60 m river: depth 3, pull 1.2, difficulty 8.6.
SELECT f.depth, f.current, public.rpg_map_swim_difficulty(f.current)
  FROM public.rpg_map_ladder() l
 CROSS JOIN LATERAL public.rpg_map_flow(7, mod(p_x - 1 + l.span, l.span), p_y - 1, 1, 1) f
 WHERE l.level = 1
   AND f.depth >= (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth')::double precision;
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
-- to map_swim_depth (1.2 m: 190). Deeper water is swum (step 7b): map_swim_pct (170), however deep. A knee-deep
-- ford, 0.5 m: 50.
WITH st AS (SELECT s.key, s.value::double precision AS v FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     p AS (SELECT (SELECT v FROM st WHERE key = 'map_wade_trickle') AS p0,
                  (SELECT v FROM st WHERE key = 'map_wade_stream_depth') AS d1, (SELECT v FROM st WHERE key = 'map_wade_stream') AS p1,
                  (SELECT v FROM st WHERE key = 'map_wade_ford_depth') AS d2, (SELECT v FROM st WHERE key = 'map_wade_ford') AS p2,
                  (SELECT v FROM st WHERE key = 'map_wade_waist_depth') AS d3, (SELECT v FROM st WHERE key = 'map_wade_waist') AS p3,
                  (SELECT v FROM st WHERE key = 'map_swim_depth') AS swim)
SELECT CASE WHEN p_depth IS NULL THEN NULL
            WHEN p_depth >= p.swim THEN (SELECT v FROM st WHERE key = 'map_swim_pct')
            WHEN p_depth <= p.d1 THEN round(p.p0 + (p.p1 - p.p0) * greatest(p_depth, 0) / p.d1)
            WHEN p_depth <= p.d2 THEN round(p.p1 + (p.p2 - p.p1) * (p_depth - p.d1) / (p.d2 - p.d1))
            WHEN p_depth <= p.d3 THEN round(p.p2 + (p.p3 - p.p2) * (p_depth - p.d2) / (p.d3 - p.d2))
            ELSE round(p.p3 + (p.p3 - p.p2) * (p_depth - p.d3) / (p.d3 - p.d2)) END::integer
  FROM p;
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
-- its depth instead (rpg_map_flow, rpg_map_wade_pct), and its hard is how deep it is, up to swimming depth (deep
-- water 1), so deeper water is drawn darker. Deep water is swum (step 7b): map_swim_pct (170), except on the battle
-- grid where it pulls too hard to swim (rpg_map_swim_difficulty: none). penalty = that percent; nothing for the sea and
-- water too rough to swim. The one way a block of the map is read with its costs: fight boards (rpg_fight_squares) and
-- the Maps tab (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the water's depth and pull only when the block holds water shallow enough to wade, or deep water on the battle
     -- grid (deep water is shaded full; on a coarser grid it is the average swim)
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth, w.current FROM public.rpg_map_flow(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind = 'water' OR (p_level = 7 AND c.kind = 'deep'))),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            WHEN c.kind = 'deep' THEN CASE WHEN wt.x IS NOT NULL AND public.rpg_map_swim_difficulty(wt.current) IS NULL THEN NULL
                                           ELSE public.rpg_map_wade_pct(coalesce(wt.depth, sw.swim)) END
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

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_costs on the battle
-- grid: the percent of time each square adds to cross it, and forest; deep water is swum, at its own percent (step
-- 7b); the sea and water too rough to swim no entry, the sea flag), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map)
SELECT g.x, g.y,
       CASE WHEN m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       coalesce(m.forest, false) OR i.forest, i.burning, coalesce(m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL), false)
  FROM s CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
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
-- ford, +150% waist-deep"), deep water that it is swum and at what time ("deeper than 1.2 m: swum, +170% time a
-- square, a Swimming roll against its pull every few seconds"); a place that only names the land reads nothing.
SELECT CASE WHEN p_kind = 'water'
            THEN '+' || public.rpg_map_wade_pct(0) || '% at a trickle, +' || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_stream_depth'))
                 || '% a stream, +' || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_ford_depth')) || '% a ford, +'
                 || public.rpg_map_wade_pct((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_wade_waist_depth')) || '% waist-deep'
            WHEN p_kind = 'deep' THEN 'deeper than ' || trim_scale((SELECT s.value::double precision FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth')::numeric)
                                      || ' m: swum, +' || public.rpg_setting('map_swim_pct')::integer || '% time a square, a Swimming roll against its pull every few seconds'
            ELSE (SELECT concat_ws(' · ', CASE WHEN p_kind = 'place' AND b.forest THEN 'forest' END,
                                   CASE WHEN b.low = b.high THEN '+' || b.low || '% time a square'
                                        ELSE '+' || b.low || '% to +' || b.high || '% time a square' END
                                   || CASE WHEN b.thicket IS NOT NULL THEN ', thickets +' || b.thicket || '%' ELSE '' END
                                   || CASE WHEN b.low <> b.high THEN ', about +' || (SELECT g.penalty FROM public.rpg_map_ground(p_kind, p_place) g) || '% on average' ELSE '' END)
                    FROM public.rpg_map_band(p_kind, p_place) b) END;
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
-- nothing when it has none; share = how many of its squares are thicket (0 when none). The sea, deep water (swum, not
-- walked: rpg_map_wade_pct), or a place that only names the land, has no row.
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

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; rivers and
-- lakes), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
-- detail; the page reads the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent
-- of time a square of it adds to cross it (the most is the same key with _high; rpg_map_band; water goes by its depth,
-- rpg_map_wade_pct; deep water is swum, step 7b; the sea = no walking in), and whether it is forest (it has trees: it burns and
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

CREATE OR REPLACE FUNCTION public.rpg_map_set_down(p_participant_id uuid, p_x integer, p_y integer, p_squares integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Puts a newly met creature on the map p_squares away from a square (world squares from 1): one of the eight ways at
-- random, on ground nobody stands on, never in the sea or in water too deep to wade (rpg_map_swim); nearer if no way is
-- free that far. Returns whether it found a square.
DECLARE v_p record; v_d integer; v_w integer; v_x integer; v_y integer; v_dir record;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  SELECT l.span INTO v_w FROM public.rpg_map_ladder() l WHERE l.level = 1;
  FOR v_d IN REVERSE greatest(p_squares, 1) .. 1 LOOP
    FOR v_dir IN SELECT d.dx, d.dy FROM (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS d(dx, dy) ORDER BY random() LOOP
      v_x := mod(p_x - 1 + v_dir.dx * v_d + v_w, v_w) + 1;
      v_y := p_y + v_dir.dy * v_d;
      CONTINUE WHEN v_y < 1 OR v_y > v_w / 2;
      CONTINUE WHEN (SELECT f.sea FROM public.rpg_fight_square(v_p.session_id, v_x, v_y) f);
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_map_swim(v_x, v_y));
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants o
                             WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = v_x AND o.pos_y = v_y
                               AND public.rpg_participant_blocks(o.id));
      UPDATE public.rpg_session_participants SET pos_x = v_x, pos_y = v_y WHERE id = p_participant_id;
      RETURN true;
    END LOOP;
  END LOOP;
  RETURN false;
END;
$function$;


CREATE OR REPLACE FUNCTION public.rpg_swim_check(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The swim at the start of a turn in water too deep to wade (Peter 2026-10-03 22:05: a roll against the water's
-- difficulty, rolled regularly while in the water; a miss ducks them under; under too long without breathing water,
-- they drown; back up, they get air). Called by rpg_session_next_turn for whoever's turn begins, on a fight board or a
-- journey. Off the water nothing happens, except that someone still Under climbs out and is no longer Under.
-- The roll: Swimming against the water's pull where they are (rpg_map_swim: still water 0.7, a river's middle 8.6).
-- With swimming gear (an item worn or held that adds to Swimming with Gear) they roll Swimming with Gear instead, gear
-- and all (Peter 2026-10-03 23:12: gear adds to the swimmer's own roll; Swimming with Gear is built on Swimming).
-- Someone whose sheet has no open Swimming swims as skill 0: only a 100 keeps them up. A creature's roll is made from
-- its sheet without training it; a character's goes through rpg_roll (it trains).
-- Made it: they keep their head up, or come up for air and are no longer Under. Missed: they go Under (cannot act, so
-- they are easier to hit and their turn passes; the next turn comes a beat later and they try again), or stay under.
-- Under holds the breath for swim_breath_ticks (180, 30 seconds); past that, unless their card breathes water
-- (rpg_creatures.breathes_water, on the card or any card above it), every tick under costs Physical Vitality at a
-- rate that takes a full bar in swim_drown_ticks (540, 90 seconds): Zaboo (16) loses 1 for every 34 ticks. At 0 they
-- are down (a character never dies). Returns {roll, needed, made, under, harm} or nothing when they are not swimming.
DECLARE
  v_p record; v_s record; v_w record; v_under jsonb; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer;
  v_made boolean; v_text text; v_breathes boolean; v_breath integer; v_drown integer; v_max integer; v_harm integer := 0;
  v_from bigint; v_roll_id uuid; v_out text; v_gear boolean;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) THEN RETURN NULL; END IF;
  SELECT e INTO v_under FROM jsonb_array_elements(v_p.effects) e WHERE e->>'name' = 'Under' LIMIT 1;
  SELECT * INTO v_w FROM public.rpg_map_swim(v_p.pos_x, v_p.pos_y);
  IF NOT FOUND THEN
    IF v_under IS NOT NULL THEN
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> 'Under')
       WHERE p.id = p_participant_id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, 'effect', 'info', p_participant_id, v_p.name || ' is out of the deep water and no longer Under.');
    END IF;
    RETURN NULL;
  END IF;
  IF (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN RETURN NULL; END IF;

  -- with swimming gear on, Swimming with Gear (gear and all) when it is open; else Swimming
  v_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'swim_gear')
            AND public.rpg_participant_value(p_participant_id, 'swim_gear') IS NOT NULL;
  v_key := CASE WHEN v_gear THEN 'swim_gear' ELSE 'WM' END;
  v_skill := public.rpg_participant_value(p_participant_id, v_key);
  IF v_p.creature_id IS NULL AND v_skill IS NOT NULL THEN
    v_r := public.rpg_roll(v_p.character_id, v_key, v_w.difficulty, 'Swimming against the water', NULL, v_s.id, p_participant_id);
    v_roll := (v_r->>'roll')::integer; v_nc := jsonb_build_object('needed', v_r->'needed', 'critical', v_r->'critical'); v_roll_id := (v_r->>'roll_id')::uuid;
  ELSE
    v_nc := public.rpg_needed(coalesce(v_skill, 0), v_w.difficulty);
    v_roll := floor(random() * 100)::integer + 1;
  END IF;
  v_made := v_roll >= (v_nc->>'needed')::numeric;
  v_out := public.rpg_outcome(v_roll, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, false, 0)->>'key';
  v_text := v_p.name || ' swims against the water (' || CASE WHEN v_gear THEN 'Swimming with Gear ' ELSE 'Swimming ' END
         || trim_scale(coalesce(v_skill, 0)) || ' against ' || trim_scale(v_w.difficulty) || '): rolls ' || v_roll || ', needs '
         || ceil((v_nc->>'needed')::numeric) || '. ';
  IF v_made THEN
    IF v_under IS NOT NULL THEN
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> 'Under')
       WHERE p.id = p_participant_id;
      v_text := v_text || 'Comes up for air.';
    ELSE
      v_text := v_text || 'Keeps their head above water.';
    END IF;
  ELSIF v_under IS NULL THEN
    UPDATE public.rpg_session_participants
       SET effects = effects || jsonb_build_array(jsonb_build_object('name', 'Under', 'cannot_act', true, 'clear', 'swim', 'source', 'the water',
                                                                     'since', v_s.clock, 'harmed_to', v_s.clock))
     WHERE id = p_participant_id;
    v_text := v_text || 'Goes under!';
  ELSE
    v_breath := public.rpg_setting('swim_breath_ticks')::integer;
    v_drown := public.rpg_setting('swim_drown_ticks')::integer;
    v_breathes := EXISTS (SELECT 1 FROM public.rpg_characters ch
                           CROSS JOIN LATERAL unnest(public.rpg_template_chain(coalesce(v_p.creature_id, ch.template_id))) AS t(id)
                           JOIN public.rpg_creatures c ON c.id = t.id
                          WHERE ch.id = v_p.character_id AND c.breathes_water);
    v_from := greatest((v_under->>'harmed_to')::bigint, (v_under->>'since')::bigint + v_breath);
    IF NOT v_breathes AND v_s.clock > v_from THEN
      v_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
      v_harm := ceil(v_max * (v_s.clock - v_from)::numeric / v_drown)::integer;
      UPDATE public.rpg_session_participants p
         SET effects = (SELECT coalesce(jsonb_agg(CASE WHEN e->>'name' = 'Under' THEN e || jsonb_build_object('harmed_to', v_s.clock) ELSE e END), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e)
       WHERE p.id = p_participant_id;
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_harm);
      v_text := v_text || 'Still under, out of breath and drowning: ' || v_harm || ' damage'
             || CASE WHEN (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN '. Down.' ELSE '.' END;
    ELSE
      v_text := v_text || 'Still under' || CASE WHEN v_breathes THEN ', breathing the water.'
                                               ELSE ', holding their breath (' || public.rpg_map_duration_text(greatest((v_under->>'since')::bigint + v_breath - v_s.clock, 0)) || ' of air left).' END;
    END IF;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out, p_participant_id, v_roll_id, v_text);
  RETURN jsonb_build_object('roll', v_roll, 'needed', v_nc->'needed', 'made', v_made, 'under', NOT v_made, 'harm', v_harm, 'text', v_text);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one on the fight clock. The turn's time is charged to the one who took it:
-- moving and acting together cost the bigger plus half the smaller (rpg_turn_cost: Zaboo walks 13 ticks and swings 27,
-- 27 + 6 = 33), or one beat of waiting when they did neither. Then whoever is next on the clock goes, the faster one on
-- a tie (Speed), then the Agility order they joined in (turn_order), so a quick fighter can act twice before a slow one
-- acts once (the Bramblemaw claws every 12 ticks, Karen swings every 36). In setup this starts the fight: everyone's
-- first turn comes one beat in (Speed 7: tick 12; Speed 1: tick 18). A new round begins every round_ticks (20): it
-- frees anyone Held from an earlier round, raises a creature whose revival wait is over (the Bramblemaw: Sunk in round
-- 5, rises with 1 when round 7 begins), gives everyone their energy regain once for each round passed, and gives
-- creatures back their legendary actions (Bramblemaw: 3). As a turn ends, every other creature with legendary actions
-- left rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one swipe at the character it scores highest on; Rootstep: a step toward the nearest character). At the start
-- of someone's turn they get up from Knocked down, what they put on others until then (clear 'source_turn': Judged)
-- comes off, and a check they tried on an earlier turn (Frightened) is due again; in water too deep to wade they swim
-- (rpg_swim_check: a Swimming roll against the water, going under or coming up for air). A creature out of the fight (dead,
-- or waiting under its card's revival rule: rpg_participant_out) gets no turn. The game master can pass any turn; a
-- player can end a character's turn, never a creature's.
DECLARE
  v_s record; v_cur record; v_next_id uuid; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric; v_cost integer; v_mv integer; v_ac integer;
  v_rt integer := public.rpg_setting('round_ticks')::integer; v_clock bigint; v_round integer; v_rounds integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT * INTO v_cur FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur.id IS NULL OR v_cur.creature_id IS NOT NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;
  PERFORM set_config('rpg.engine', 'on', true);

  IF v_s.status = 'active' AND v_cur.id IS NOT NULL THEN
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur.id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      v_best := NULL; v_top := 0;
      FOR v_la IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                   WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
                     AND public.rpg_action_ready(v_a.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_a.id, v_la.id, v_tg);
        IF (v_pick->>'score')::numeric > v_top THEN
          v_top := (v_pick->>'score')::numeric;
          v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets', 'square', v_pick->'square');
        END IF;
      END LOOP;
      CONTINUE WHEN v_best IS NULL;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || (v_best->>'name') || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        IF jsonb_typeof(v_best->'square') = 'object' THEN
          PERFORM public.rpg_act_square(v_a.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
        ELSE
          PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
        END IF;
      END IF;
    END LOOP;
    SELECT turn_move_ticks, turn_action_ticks INTO v_mv, v_ac FROM public.rpg_sessions WHERE id = p_session_id;
    v_cost := public.rpg_turn_cost(v_mv, v_ac);
    IF v_cost = 0 THEN v_cost := public.rpg_action_ticks(v_cur.id, 1); END IF;
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + v_cost WHERE id = v_cur.id;
  ELSIF v_s.status = 'setup' THEN
    UPDATE public.rpg_session_participants SET next_tick = public.rpg_action_ticks(id, 1) WHERE session_id = p_session_id;
  END IF;

  SELECT p.id INTO v_next_id FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND NOT public.rpg_participant_out(p.id)
   ORDER BY coalesce(p.next_tick, v_s.clock), public.rpg_participant_speed(p.id) DESC, p.turn_order, p.created_at LIMIT 1;
  IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  v_clock := greatest(coalesce(v_next.next_tick, v_s.clock), v_s.clock);
  IF v_s.status = 'setup' THEN
    v_round := 1;
  ELSE
    v_round := greatest(v_clock / v_rt + 1, v_s.round);
    v_rounds := v_round - v_s.round;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, clock = v_clock, current_participant_id = v_next_id,
         turn_move_ticks = 0, turn_action_ticks = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'info', CASE WHEN v_s.on_map THEN 'The journey begins.' ELSE 'The fight begins. Round 1.' END);
  ELSIF v_rounds > 0 THEN
    -- a journey passes thousands of rounds a walk: everything a round brings still happens, without a line in the log
    IF NOT v_s.on_map THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'round', 'info', 'Round ' || v_round || ' begins.');
    END IF;
    FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'round' AND (e->>'round')::integer < v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
       WHERE p.id = v_a.id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
    END LOOP;
    FOR v_a IN SELECT p.id, p.name, p.character_id, e AS eff FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'revive' AND (e->>'until_round')::integer <= v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
       WHERE p.id = v_a.id;
      UPDATE public.rpg_characters c
         SET vitality_damage = greatest((public.rpg_participant_vitality(v_a.id)->>'max')::integer - coalesce((v_a.eff->>'revive')::integer, 1), 0)
       WHERE c.id = v_a.character_id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id,
              v_a.name || ' rises with ' || coalesce((v_a.eff->>'revive')::integer, 1) || ' vitality.');
    END LOOP;
    UPDATE public.rpg_session_participants
       SET energy_used_physical = greatest(energy_used_physical - v_rounds * coalesce(public.rpg_participant_value(id, 'PER'), 0)::integer, 0),
           energy_used_spiritual = greatest(energy_used_spiritual - v_rounds * coalesce(public.rpg_participant_value(id, 'SER'), 0)::integer, 0),
           legendary_left = CASE WHEN creature_id IS NOT NULL
                                 THEN coalesce((SELECT c.legendary_per_round FROM public.rpg_creatures c WHERE c.id = creature_id), 0)
                                 ELSE legendary_left END
     WHERE session_id = p_session_id;
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename, coalesce((e->>'cannot_act')::boolean, false) AS held FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || CASE WHEN v_a.held THEN ' gets up. No longer ' ELSE ' is no longer ' END || v_a.ename || '.');
  END LOOP;
  UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e - 'checked_round'), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e)
   WHERE p.id = v_next_id AND EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) e WHERE e ? 'checked_round');
  FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
              WHERE p.session_id = p_session_id AND e->>'clear' = 'source_turn' AND e->>'source_id' = v_next_id::text LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' <> v_a.ename)
     WHERE p.id = v_a.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
  END LOOP;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  PERFORM public.rpg_swim_check(v_next_id);
  RETURN jsonb_build_object('round', v_round, 'clock', v_clock, 'current_participant_id', v_next_id);
END;
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
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN RAISE EXCEPTION 'that square is sea or water too rough to swim'; END IF;
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
--   at the shore: nobody walks into the sea (2A), nor into water too rough to swim, nor ends a walk in water too deep
--   to wade; the piece stands on the last dry square before it;
--   water too deep to wade is swum (step 7b): each square takes map_swim_pct (170) more time, and every round_ticks (20)
--   in the water the site rolls the swimmer's Swimming (Swimming with Gear with swimming gear on) against the water's
--   pull there (rpg_map_swim_difficulty). A miss puts them under: a round lost, and they roll again; under longer than
--   swim_breath_ticks (180) without breathing water, every tick costs vitality at a full bar per swim_drown_ticks (540).
--   Once in the water they swim on until out of it, past the end of the walking day if need be; if they go down
--   (0 vitality) the walk stops there, in the water. The rolls train the skill like any roll (all their points at once);
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
  v_wc double precision; v_swim boolean; v_dif numeric; v_rtk integer; v_breath integer; v_drown integer; v_lost numeric; v_need2 numeric;
  v_sw_in boolean := false; v_sw_clock numeric := 0; v_sw_next numeric := 0; v_sw_under integer := 0; v_sw_long integer := 0; v_sw_dips integer := 0;
  v_sw_rolls integer := 0; v_sw_points numeric := 0; v_sw_harmt integer := 0; v_sw_harm integer := 0; v_sw_key text; v_sw_skill numeric; v_sw_gear boolean;
  v_sw_breathes boolean; v_sw_left integer; v_sw_max integer; v_sw_maxdif numeric := 0; v_sw_val numeric;
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
  FOR v_pass IN 1 .. 80 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, v_gx, v_gy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0; v_wc := 0; v_swim := false;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_r.kind IN ('water', 'deep') OR v_r.level < 7 THEN
        SELECT w.depth, w.line, w.current INTO v_wd, v_wl, v_wc
          FROM public.rpg_map_flow(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_r.kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF v_r.kind = 'deep' AND v_r.level = 7 THEN
        -- water too deep to wade, on the battle grid: swum (step 7b), unless it pulls too hard to swim or the walk
        -- would end in it (then it stops at the water's edge)
        v_dif := public.rpg_map_swim_difficulty(v_wc);
        IF v_dif IS NOT NULL AND v_r.k_to < v_steps THEN v_pen := public.rpg_map_wade_pct(v_wd); v_swim := true; END IF;
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep)) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_r.kind, v_r.place_id) b;
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
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A); none in the water
      IF v_n > 0 AND NOT v_swim THEN
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
      EXIT WHEN v_why IN ('meet', 'drown');
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

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back; someone
  -- who went down in the water stays where they went down
  IF v_why = 'drown' THEN v_k := v_reach; END IF;
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
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') <> 'drown' AND v_p.day_walk_ticks + v_walk >= v_day);
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone is in the way' END;
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
  -- what the character saw on the way (rpg_map_found reads these stretches)
  IF v_k > 0 THEN PERFORM public.rpg_map_trail_add(v_p.character_id, v_sx + 1, v_sy + 1, v_tx + 1, v_ty + 1); END IF;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk) || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'shore' THEN ' The sea, water too rough to swim, or the water''s edge stops the walk.' ELSE '' END
         || CASE WHEN v_sw_rolls > 0 THEN ' Swims deep water: ' || v_sw_rolls || ' Swimming rolls' || CASE WHEN v_sw_gear THEN ' with gear' ELSE '' END
                                          || ' (' || trim_scale(coalesce(v_sw_skill, 0)) || ' against up to ' || trim_scale(v_sw_maxdif) || ')'
                                          || CASE WHEN v_sw_dips > 0 THEN ', under water ' || v_sw_dips || CASE WHEN v_sw_dips = 1 THEN ' time' ELSE ' times' END
                                                  || ', the longest ' || public.rpg_map_duration_text(v_sw_long) ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_sw_harmt > 0 THEN ' Out of breath under water: ' || ceil(v_sw_max * v_sw_harmt::numeric / v_drown) || ' damage.' ELSE '' END
         || CASE WHEN v_why = 'drown' THEN ' Goes down in the water.' ELSE '' END
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


-- Swimming with Gear (Peter 2026-10-03 23:12): a skill built on Swimming; gear adds to it (an item's bonus).
INSERT INTO public.rpg_stat_definitions (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, reach, spirit_discipline, template_id)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'swim_gear', 'Swimming with Gear', 'SWG', 'ability', 'derived', true, '{"div": 1, "parts": [["WM", 1]]}'::jsonb, 0, 481, false, 2, 4, 'physical', 1, false, '58b4e57e-db74-428a-9883-a3acc029d1ac'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'swim_gear');

-- Rule cards
INSERT INTO public.rpg_rules (agency_id, key, title, body, source, sort_order, section)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'swimming', 'Swimming', $card$Water deeper than 1.2 m (chest-deep) is swum, not waded. A square of it takes +170% time: swimming at about 0.5 m/s against walking at 1.34 m/s.
*A deep square is 5 × 2.7 = 13.5 base ticks: 14 ticks at Speed 10, 25 for Karen (Speed 1).*

A swimmer rolls Swimming against the water's pull, again and again while in it. Water flowing as fast as an average swimmer swims (0.7 m/s) is difficulty 5, and the difficulty rises in step with the pull: difficulty = 5 × pull ÷ 0.7. Still lakes and ponds count their small waves, 0.1 m/s: difficulty 0.7. A river is fastest in its middle and slower toward its banks: a great river pulls 1.8 m/s in the middle (difficulty 12.9), a river 1.2 (8.6), a stream 0.6 (4.3). Water pulling 2.1 m/s or more, faster than the fastest swimmers, cannot be swum at all: it takes a boat.
*Karen (Swimming 7) in a still lake needs 100 × 0.7 ÷ (0.7 + 7) = 10 or more: she stays up about 9 times in 10. In the middle of a river (8.6) she needs 56.*

On a fight board the roll comes at the start of each turn in deep water. Make it and you swim on: move and act as usual. Miss it and you go Under: you cannot act, so blows against you face your Evade Enemy × 1, and your turn passes; your next turn comes a beat later and you roll again. Make it then and you come up for air.

Under, you hold your breath 30 seconds (180 ticks). Past that you drown: every tick under costs Physical Vitality, a whole bar in 90 more seconds (540 ticks). At 0 you are down (a character never dies). Back up, you have air again. A being whose card breathes water goes under but never drowns.
*Zaboo (Physical Vitality 16) under for 40 seconds (240 ticks) is 60 ticks past his breath: 16 × 60 ÷ 540 = 1.8, so 2 damage.*

On a journey the site swims for you: a roll every round (20 ticks, about 3 seconds) in the water, and a miss costs a round under before you roll again. Once in the water you swim on until you are out of it, past the end of the walking day if need be; if you go down, the walk stops there, in the water. A walk never ends in deep water: aimed at a square in it, it stops at the edge. Every roll trains Swimming like any roll.
*A 60 m river is too deep to wade across its middle 47 m, 42 squares: 42 × 13.5 = 567 ticks at Speed 10 (about a minute and a half) and 28 rolls, plus a round for every miss.*

Swimming gear (fins, a float) adds to the swimmer's own roll. With gear worn or held, the roll is Swimming with Gear, a skill built on Swimming (it starts at your Swimming and trains on its own), plus what the gear adds.
*Fins that add 2 to Swimming with Gear make Karen's roll 7 + 2 = 9 while she wears them.*$card$, 'peter', 49, 'Fights'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules r WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND r.key = 'swimming');
UPDATE public.rpg_rules SET body = replace(body,
'water deeper than 1.2 m (chest-deep) has to be swum, and until swimming comes nobody steps into it.',
'water deeper than 1.2 m (chest-deep) is swum, at +170%, with a Swimming roll at the start of every turn in it (see Swimming).'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving';
UPDATE public.rpg_rules SET body = replace(replace(body,
'Water deeper than 1.2 m is swum, not waded; until swimming comes, a walk stops at its edge, so a great river or a river is a wall without a bridge or a boat.',
'Water deeper than 1.2 m is swum, not waded: the walk swims across it, rolling Swimming every few seconds (see Swimming).'),
'Nobody walks into the sea or into water too deep to wade. A walk that reaches it stops on the last dry square.',
'Nobody walks into the sea or into water too rough to swim, and a walk never ends in deep water. A walk that reaches either stops on the last dry square.'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map';

