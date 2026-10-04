-- Step 8a (Peter 2026-10-03 17:28 "more towns"; 2026-10-04 03:47 "Proceed"): villages, towns and cities on the world
-- map, worked out from the land when asked and never stored, the way rivers and climates are. Roads between places come
-- next (8b), then buildings that are climbed by the cliff rule (8c).
-- Real numbers. Where they sit follows central place theory (Christaller 1933): a lattice of village sites, every town
-- at one of them, every city at one of the town sites, so they never crowd each other. How many: good open land is as
-- crowded as the farmland of England was. The Domesday Book (1086) names about 13,400 places in England, one for every
-- 3.7 square miles: a village every 2.1 miles. About 800 market towns served England and Wales c. 1600 (Everitt 1967):
-- one every 9 miles. Four English cities held 10,000 people or more c. 1300 (London, York, Norwich, Bristol): one in
-- about 12,600 square miles, a city every 110 miles or so. Forest, hills and harder ground hold fewer, as farming
-- country does; none grow in water, on snow and ice, or inside a place with ground of its own (a haunt, Old Forest,
-- Haven). Sizes: a village of 100 to 400 people, its houses each in a garden plot, about 20 a hectare; a town of 500 to
-- 5,000 at about 100 a hectare; a city of 8,000 to 16,000 at about 150 a hectare (medieval towns held 100 to 200 a
-- hectare inside their walls). Their streets and yards are walked like open land, +0% to +10% time a square (a dirt
-- road takes about 1.1 times as long as a paved one, Soule and Goldman 1972).
-- The Country grid marks its cities, the Region grid all three, the City grid and finer show their ground; the Region
-- grid lists its towns and cities. New: rpg_map_town_radius, rpg_map_town_sites, rpg_map_town_make, rpg_map_towns,
-- rpg_map_town_cells, rpg_map_town_entry. Changed in place: rpg_map_grounds (town), rpg_map_icons (town, city),
-- rpg_map_cells (town ground), rpg_map_view_block (marks, ground, towns list, detail). No drops, no table changes.
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_town_penalty', 0::numeric, 'Villages, towns and cities: least percent of time a square of their streets and yards adds (like open land)'),
               ('map_town_penalty_high', 10, 'Villages, towns and cities: most percent of time a square of their streets and yards adds (a dirt road is about 1.1 times a paved one, Soule and Goldman 1972)'),
               ('map_village_lattice', 2592, 'Settlements: each square this many squares across (1.8 miles) holds one site where a village could stand'),
               ('map_town_lattice', 10368, 'Settlements: each square this many squares across (7.2 miles, 4 x 4 village squares) picks one of its sites for a town'),
               ('map_city_lattice', 124416, 'Settlements: each square this many squares across (86 miles, 12 x 12 town squares) picks one of its town sites for a city'),
               ('map_town_jitter', 0.6, 'Settlements: a site sits in this middle share of its square each way (20 to 80 in 100), so sites stay at least 0.72 miles apart'),
               ('map_village_share', 0.87, 'Villages: share of sites on open land that hold one (Domesday Book 1086: about 13,400 places in England, one per 3.7 square miles)'),
               ('map_town_share', 0.7, 'Towns: share of town sites on open land that hold one (about 800 market towns in England and Wales c. 1600, Everitt 1967)'),
               ('map_city_share', 0.6, 'Cities: share of city sites on open land that hold one (four English cities of 10,000 or more c. 1300: London, York, Norwich, Bristol)'),
               ('map_village_people_low', 100, 'Villages: fewest people'),
               ('map_village_people_high', 400, 'Villages: most people'),
               ('map_town_people_low', 500, 'Towns: fewest people'),
               ('map_town_people_high', 5000, 'Towns: most people'),
               ('map_city_people_low', 8000, 'Cities: fewest people'),
               ('map_city_people_high', 16000, 'Cities: most people'),
               ('map_village_density', 20, 'Villages: people a hectare (each house in its garden plot)'),
               ('map_town_density', 100, 'Towns: people a hectare (medieval towns held 100 to 200 inside their walls)'),
               ('map_city_density', 150, 'Cities: people a hectare'),
               ('map_town_edge', 0.12, 'Settlements: how far the edge wanders in or out, share of the reach'),
               ('map_town_clear', 300, 'Settlements: none within this many squares (1,100 feet) of a place with ground of its own'),
               ('map_settle_land', 1, 'Settlements: how well open land is settled (1 = the full shares)'),
               ('map_settle_plains', 1, 'Settlements: how well grassy plains are settled'),
               ('map_settle_forest', 0.5, 'Settlements: how well forest is settled'),
               ('map_settle_hills', 0.6, 'Settlements: how well hills are settled'),
               ('map_settle_pine', 0.2, 'Settlements: how well pine forest is settled'),
               ('map_settle_jungle', 0.2, 'Settlements: how well jungle is settled'),
               ('map_settle_mountains', 0.15, 'Settlements: how well mountains are settled'),
               ('map_settle_swamp', 0.15, 'Settlements: how well swamp is settled'),
               ('map_settle_desert', 0.05, 'Settlements: how well desert is settled'),
               ('map_settle_tundra', 0.05, 'Settlements: how well tundra is settled')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; rivers and
-- lakes; villages, towns and cities, step 8), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
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
               (14, 'deep', 'Deep water', 'k', NULL, false),
               (15, 'town', 'Village, town or city', 'n', 'map_town_penalty', false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_icons()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $fn$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp) are symbols too. So are
-- a town and a city (step 8: the villages, towns and cities that grow on the land, rpg_map_towns).
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'town', 'city'];
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_radius(p_kind text, p_people integer)
 RETURNS double precision
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How far a village, town or city reaches from its middle, in squares, before its edge wanders (rpg_map_town_make;
-- step 8): the round of ground its people live on at the crowding of its kind (rpg_settings map_<kind>_density,
-- people a hectare: the houses of a village each stand in a garden plot, 20 a hectare; a medieval town about 100; a city
-- 150). A square is the metres round the world (map_world_miles, 24,901, at 1,609.344 m a mile) over the squares
-- round it: 1.118 m.
-- A village of 250 people covers 12.5 hectares: sqrt(125,000 m² / pi) = 199 m, 178 squares. A town of 2,000 at 100 a
-- hectare: 252 m, 226 squares. A city of 12,000 at 150 a hectare: 505 m, 451 squares.
SELECT sqrt(p_people * 10000.0 / d.value::double precision / pi()) / (m.value::double precision * 1609.344 / l.span)
  FROM public.rpg_settings d
  JOIN public.rpg_settings m ON m.agency_id = d.agency_id AND m.key = 'map_world_miles'
 CROSS JOIN (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) l
 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'map_' || p_kind || '_density';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_sites(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, x bigint, y bigint, city boolean, town boolean, rolls integer[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a village, town or city could stand on a block of any grid, worked out when asked and never stored: the one
-- home of where settlements sit (step 8; Peter 2026-10-03 17:28: more towns). The sites follow central place theory
-- (Christaller 1933): the land is cut into squares of map_village_lattice (2,592 squares, 1.8 miles) and each holds one
-- site, at a steady spot within the middle map_town_jitter (0.6) of it each way, so two sites always stand at least
-- 1,037 squares (0.72 miles) apart. Every square of map_town_lattice (4 x 4 village squares, 7.2 miles) picks one of
-- its sites for a town, and every square of map_city_lattice (12 x 12 town squares, 86 miles) picks one of its town
-- sites for a city: a town grows at the site of a village and a city at the site of a town, so they never crowd each
-- other.
-- Whether anything grows there, and what, is rpg_map_town_make.
-- id = site-<column>-<row> of its village square, the same seen from any block; x, y = the site in world squares from
-- 0, counted the way the block counts (a block past the east or west end of the world keeps its own count); city,
-- town = the site of a city or of a town; rolls = its fixed-seed d100s (rpg_map_roll part 11, layers 1131 to 1144): whether
-- a city, a town and a village grow there, how many people, its name (4) and how its edge wanders (6).
-- What a block gets: the World and Continent grids nothing; the Country grid the city sites whose middle lies on it
-- (it shows only cities); the Region grid every site whose middle lies on it; a finer grid every site whose biggest
-- possible ground (rpg_map_town_radius of the most people of each kind, its edge out by map_town_edge) reaches it.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     cfg AS MATERIALIZED (
       SELECT q.*, q.lt / q.lv AS nv, q.lc / q.lt AS nt, q.world / q.lv AS av, q.world / q.lt AS at, q.world / q.lc AS ac,
              greatest(q.rv, q.rt, q.rc) AS reach
         FROM (SELECT (SELECT st.value FROM st WHERE st.key = 'map_seed')::integer AS seed,
                      (SELECT st.value FROM st WHERE st.key = 'map_village_lattice')::bigint AS lv,
                      (SELECT st.value FROM st WHERE st.key = 'map_town_lattice')::bigint AS lt,
                      (SELECT st.value FROM st WHERE st.key = 'map_city_lattice')::bigint AS lc,
                      (SELECT st.value FROM st WHERE st.key = 'map_town_jitter')::double precision AS jit,
                      l.cell::bigint AS cell, w.span::bigint AS world, (w.span / 2)::bigint AS down,
                      -- how far the ground of the biggest village, town and city can reach from its site
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('village', (SELECT st.value FROM st WHERE st.key = 'map_village_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rv,
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('town', (SELECT st.value FROM st WHERE st.key = 'map_town_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rt,
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('city', (SELECT st.value FROM st WHERE st.key = 'map_city_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rc
                 FROM public.rpg_map_ladder() l CROSS JOIN public.rpg_map_ladder() w
                WHERE l.level = p_level AND w.level = 1 AND p_level >= 3) q),
     -- the squares of the world the block reaches, x from x0 up to x1, y from y0 up to y1 (not including x1, y1)
     bx AS (SELECT p_x0::bigint * cfg.cell - cfg.reach AS x0, (p_x0 + p_cols)::bigint * cfg.cell + cfg.reach AS x1,
                   greatest(p_y0::bigint * cfg.cell - cfg.reach, 0) AS y0, least((p_y0 + p_rows)::bigint * cfg.cell + cfg.reach, cfg.down) AS y1
              FROM cfg),
     -- the Country grid: each city square the block reaches, the town square it picks (k = 0 to 143), then the
     -- village square that town square picks (m = 0 to 15)
     cc AS (SELECT t.tx, t.ty, (t.tx * cfg.nv + mod(m.m, cfg.nv)) AS vx, (t.ty * cfg.nv + m.m / cfg.nv) AS vy
              FROM cfg CROSS JOIN bx
             CROSS JOIN LATERAL generate_series(floor(bx.x0::double precision / cfg.lc)::bigint, floor((bx.x1 - 1)::double precision / cfg.lc)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(bx.y0::double precision / cfg.lc)::bigint, floor((bx.y1 - 1)::double precision / cfg.lc)::bigint) AS b
             CROSS JOIN LATERAL (SELECT mod(mod(a, cfg.ac) + cfg.ac, cfg.ac) AS aw) w
             CROSS JOIN LATERAL (SELECT mod((public.rpg_map_roll(cfg.seed, 1121, w.aw::integer, b::integer) - 1) * 100
                                            + public.rpg_map_roll(cfg.seed, 1122, w.aw::integer, b::integer) - 1, cfg.nt * cfg.nt) AS k) k
             CROSS JOIN LATERAL (SELECT a * cfg.nt + mod(k.k, cfg.nt) AS tx, b * cfg.nt + k.k / cfg.nt AS ty) t
             CROSS JOIN LATERAL (SELECT mod((public.rpg_map_roll(cfg.seed, 1111, mod(mod(t.tx, cfg.at) + cfg.at, cfg.at)::integer, t.ty::integer) - 1) * 100
                                            + public.rpg_map_roll(cfg.seed, 1112, mod(mod(t.tx, cfg.at) + cfg.at, cfg.at)::integer, t.ty::integer) - 1, cfg.nv * cfg.nv) AS m) m
             WHERE p_level = 3),
     -- every village square the block reaches (the Region grid and finer), or on the Country grid only the sites the
     -- city squares picked
     vs AS (SELECT a AS vx, b AS vy
              FROM cfg CROSS JOIN bx
             CROSS JOIN LATERAL generate_series(floor(bx.x0::double precision / cfg.lv)::bigint, floor((bx.x1 - 1)::double precision / cfg.lv)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(bx.y0::double precision / cfg.lv)::bigint, floor((bx.y1 - 1)::double precision / cfg.lv)::bigint) AS b
             WHERE p_level >= 4
            UNION ALL
            SELECT cc.vx, cc.vy FROM cc),
     q AS MATERIALIZED (
       SELECT v.vx, v.vy, w.vw,
              v.vx * cfg.lv + floor(cfg.lv * ((1 - cfg.jit) / 2 + cfg.jit * (public.rpg_map_roll(cfg.seed, 1101, w.vw::integer, v.vy::integer) - 0.5) / 100))::bigint AS x,
              v.vy * cfg.lv + floor(cfg.lv * ((1 - cfg.jit) / 2 + cfg.jit * (public.rpg_map_roll(cfg.seed, 1102, w.vw::integer, v.vy::integer) - 0.5) / 100))::bigint AS y,
              h.town, h.town AND h2.city AS city
         FROM vs v CROSS JOIN cfg
        CROSS JOIN LATERAL (SELECT mod(mod(v.vx, cfg.av) + cfg.av, cfg.av) AS vw,
                                   floor(v.vx::double precision / cfg.nv)::bigint AS tx, floor(v.vy::double precision / cfg.nv)::bigint AS ty) w
        -- is it the site its town square picked?
        CROSS JOIN LATERAL (SELECT mod((public.rpg_map_roll(cfg.seed, 1111, mod(mod(w.tx, cfg.at) + cfg.at, cfg.at)::integer, w.ty::integer) - 1) * 100
                                       + public.rpg_map_roll(cfg.seed, 1112, mod(mod(w.tx, cfg.at) + cfg.at, cfg.at)::integer, w.ty::integer) - 1, cfg.nv * cfg.nv) AS m) m
        CROSS JOIN LATERAL (SELECT v.vx = w.tx * cfg.nv + mod(m.m, cfg.nv) AND v.vy = w.ty * cfg.nv + m.m / cfg.nv AS town) h
        -- and is its town square the one its city square picked?
        CROSS JOIN LATERAL (SELECT floor(w.tx::double precision / cfg.nt)::bigint AS cx, floor(w.ty::double precision / cfg.nt)::bigint AS cy) c
        CROSS JOIN LATERAL (SELECT CASE WHEN NOT h.town THEN 0
                                        ELSE mod((public.rpg_map_roll(cfg.seed, 1121, mod(mod(c.cx, cfg.ac) + cfg.ac, cfg.ac)::integer, c.cy::integer) - 1) * 100
                                                 + public.rpg_map_roll(cfg.seed, 1122, mod(mod(c.cx, cfg.ac) + cfg.ac, cfg.ac)::integer, c.cy::integer) - 1, cfg.nt * cfg.nt) END AS k) k
        CROSS JOIN LATERAL (SELECT h.town AND w.tx = c.cx * cfg.nt + mod(k.k, cfg.nt) AND w.ty = c.cy * cfg.nt + k.k / cfg.nt AS city) h2)
SELECT 'site-' || q.vw || '-' || q.vy, q.x, q.y, q.city, q.town,
       ARRAY(SELECT public.rpg_map_roll(cfg.seed, 1130 + n, q.vw::integer, q.vy::integer) FROM generate_series(1, 14) AS n ORDER BY n)
  FROM q CROSS JOIN cfg
 -- a site only a village can grow at reaches no farther than the biggest village, a town site than the biggest town
 CROSS JOIN LATERAL (SELECT CASE WHEN q.city THEN cfg.reach WHEN q.town THEN greatest(cfg.rt, cfg.rv) ELSE cfg.rv END AS r) r
 WHERE q.x >= p_x0::bigint * cfg.cell - r.r AND q.x < (p_x0 + p_cols)::bigint * cfg.cell + r.r
   AND q.y >= p_y0::bigint * cfg.cell - r.r AND q.y < (p_y0 + p_rows)::bigint * cfg.cell + r.r
   AND (p_level <> 3 OR q.city);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_make(p_x bigint, p_y bigint, p_city boolean, p_town boolean, p_rolls integer[], p_country text, p_region text)
 RETURNS TABLE(kind text, name text, people integer, r double precision, shape double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What grows at a site (rpg_map_town_sites), the one home of it (step 8): a city, a town, a village or nothing, how
-- many people live there, how far it reaches, its name and how its edge wanders. Worked out when asked, never stored.
-- The site of a city grows a city when its roll is under map_city_share times how well the ground of its Country cell is
-- settled (map_settle_<ground>); if not, the site of a town grows a town on map_town_share times the ground of its Region
-- cell; if not, any site grows a village on map_village_share times the ground of its Region cell. The shares make
-- good open land as crowded as the farmland of England was: the Domesday Book (1086) names about 13,400 places in England,
-- one for every 3.7 square miles, a village every 2.1 miles; about 800 market towns served England and Wales c. 1600
-- (Everitt 1967), one for every 73 square miles; four English cities held 10,000 people or more c. 1300 (London,
-- York, Norwich, Bristol), one for every 12,600 square miles. The ground thins them, as farming country does: forest
-- half as many, hills 0.6, pine forest and jungle 0.2, mountains and swamp 0.15, desert and tundra 0.05, none on snow
-- and ice, on water or in the sea. Nothing grows inside a place with ground of its own (a haunt, Old Forest, Haven) or
-- within map_town_clear (300 squares, 1,100 feet) of one.
-- people: a steady roll from the least to the most of its kind (map_<kind>_people_low / _high), as many small ones as
-- big on a doubling scale (100 to 400 a village: half under 200), rounded to 10. r = rpg_map_town_radius.
-- shape: how its edge wanders round its middle, three waves of 2, 3 and 4 bumps a turn, of up to half, three tenths
-- and a fifth of map_town_edge (12 in 100) of r: [size, turn] of each.
-- name: a first part and an ending, the way English places were named (Ash + ford, Oak + ham, Thorn + bury);
-- the ending of a village fits its ground (a wood, a hill, a mere), that of a town or a city its size.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     k AS (SELECT CASE WHEN p_city AND (p_rolls[1] - 0.5) / 100
                                       < (SELECT st.value FROM st WHERE st.key = 'map_city_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_country), 0) THEN 'city'
                       WHEN p_town AND (p_rolls[2] - 0.5) / 100
                                       < (SELECT st.value FROM st WHERE st.key = 'map_town_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_region), 0) THEN 'town'
                       WHEN (p_rolls[3] - 0.5) / 100
                            < (SELECT st.value FROM st WHERE st.key = 'map_village_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_region), 0) THEN 'village' END AS kind),
     pp AS (SELECT k.kind, (round(b.lo * power(b.hi / b.lo, (p_rolls[4] - 0.5) / 100) / 10) * 10)::integer AS people
              FROM k
             CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_' || k.kind || '_people_low')::double precision AS lo,
                                        (SELECT st.value FROM st WHERE st.key = 'map_' || k.kind || '_people_high')::double precision AS hi) b
             WHERE k.kind IS NOT NULL),
     rr AS (SELECT pp.kind, pp.people, public.rpg_map_town_radius(pp.kind, pp.people) AS r,
                   (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision AS edge,
                   (SELECT st.value FROM st WHERE st.key = 'map_town_clear')::double precision AS clear
              FROM pp),
     nm AS (SELECT ARRAY['Ash', 'Oak', 'Elm', 'Thorn', 'Hazel', 'Alder', 'Birch', 'Willow', 'Holly', 'Rowan', 'Yew', 'Stone',
                         'Clay', 'Chalk', 'Flint', 'Mill', 'Brook', 'Well', 'Moor', 'Heath', 'Black', 'White', 'Red', 'Green',
                         'Long', 'Broad', 'High', 'North', 'South', 'East', 'West', 'Kings', 'Queens', 'Bishops', 'Abbots', 'Swan',
                         'Hart', 'Fox', 'Hawk', 'Crane', 'Buck', 'Ox', 'Barley', 'Wheat', 'Apple', 'Honey', 'Salt', 'Iron',
                         'Bell', 'Cross', 'Fair', 'Bright', 'Wolf', 'Hare', 'Lark', 'Wren', 'Elder', 'Cold', 'Wind', 'Rush',
                         'Reed', 'Hay', 'Cherry', 'Merry'] AS firsts,
                   CASE WHEN rr.kind = 'city' THEN ARRAY['bury', 'chester', 'minster', 'caster', 'ford', 'bridge', 'ham', 'borough', 'wick']
                        WHEN rr.kind = 'town' THEN ARRAY['ford', 'bridge', 'ham', 'ton', 'bury', 'wick', 'field', 'stow', 'borough', 'worth']
                        WHEN p_region IN ('forest', 'pine', 'jungle') THEN ARRAY['wood', 'hurst', 'den', 'ley', 'holt', 'field', 'ridge']
                        WHEN p_region IN ('hills', 'mountains') THEN ARRAY['don', 'combe', 'ley', 'hill', 'low', 'dale', 'side']
                        WHEN p_region = 'swamp' THEN ARRAY['mere', 'fen', 'ey', 'marsh', 'holm']
                        WHEN p_region IN ('desert', 'tundra') THEN ARRAY['well', 'stead', 'by', 'cote']
                        ELSE ARRAY['ton', 'ham', 'stead', 'thorpe', 'by', 'wick', 'cote', 'worth', 'field', 'ley', 'well', 'brook', 'ford'] END AS ends
              FROM rr),
     pn AS (SELECT nm.firsts[1 + mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, cardinality(nm.firsts))] AS a,
                   nm.ends[1 + mod((p_rolls[7] - 1) * 100 + p_rolls[8] - 1, cardinality(nm.ends))] AS b
              FROM nm)
SELECT rr.kind,
       CASE WHEN lower(right(pn.a, 1)) = left(pn.b, 1) THEN pn.a || substr(pn.b, 2) ELSE pn.a || pn.b END,
       rr.people, rr.r,
       ARRAY[rr.edge * 0.5 * ((p_rolls[9] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[10] - 0.5) / 100,
             rr.edge * 0.3 * ((p_rolls[11] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[12] - 0.5) / 100,
             rr.edge * 0.2 * ((p_rolls[13] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[14] - 0.5) / 100]
  FROM rr CROSS JOIN pn
 CROSS JOIN (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) l
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures c
                    WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL AND c.place_penalty IS NOT NULL
                      AND public.rpg_map_covers(p_x + 0.5::double precision, p_y + 0.5::double precision, c.place_x, c.place_y,
                                                ceil(c.place_w + 2 * (rr.r + rr.clear))::integer, ceil(c.place_h + 2 * (rr.r + rr.clear))::integer, l.span));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_towns(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_kinds jsonb)
 RETURNS TABLE(id text, kind text, name text, people integer, x bigint, y bigint, r double precision, shape double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The villages, towns and cities a block of any grid shows (step 8): its sites (rpg_map_town_sites) and what grows at
-- each (rpg_map_town_make), the one way they are read. The Country grid shows its cities, the Region grid all three,
-- a finer grid every one whose ground reaches it. A site is decided by the ground of the cell it stands in, a city by
-- its Country cell and a town or a village by its Region cell (rpg_map_cells), so the same site grows the same thing
-- seen from any grid. p_kinds = the kinds of the cells of this very block when the caller already has them ("x,y":
-- kind, as rpg_map_cells counts them), so a Country or Region grid is not worked out twice; else nothing.
WITH s AS MATERIALIZED (SELECT * FROM public.rpg_map_town_sites(p_level, p_x0, p_y0, p_cols, p_rows)),
     lc AS (SELECT (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 3)::bigint AS c3,
                   (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 4)::bigint AS c4),
     sc AS MATERIALIZED (
       SELECT s.*, floor(s.x::double precision / lc.c3)::integer AS x3, floor(s.y::double precision / lc.c3)::integer AS y3,
              floor(s.x::double precision / lc.c4)::integer AS x4, floor(s.y::double precision / lc.c4)::integer AS y4
         FROM s CROSS JOIN lc),
     -- the Region cells under the sites (the Region grid and finer), read once as a block
     rb AS (SELECT min(sc.x4) AS x0, min(sc.y4) AS y0, max(sc.x4) - min(sc.x4) + 1 AS cols, max(sc.y4) - min(sc.y4) + 1 AS rows
              FROM sc WHERE p_level >= 4 AND NOT (p_level = 4 AND p_kinds IS NOT NULL) HAVING count(*) > 0),
     rk AS MATERIALIZED (
       SELECT c.x, c.y, c.kind FROM rb CROSS JOIN LATERAL public.rpg_map_cells(4, rb.x0, rb.y0, rb.cols, rb.rows) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 4),
     -- the Country cell under the site of each city
     ck AS MATERIALIZED (
       SELECT d.x3 AS x, d.y3 AS y, c.kind
         FROM (SELECT DISTINCT sc.x3, sc.y3 FROM sc WHERE sc.city AND NOT (p_level = 3 AND p_kinds IS NOT NULL)) d
        CROSS JOIN LATERAL public.rpg_map_cells(3, d.x3, d.y3, 1, 1) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 3)
SELECT sc.id, m.kind, m.name, m.people, sc.x, sc.y, m.r, m.shape
  FROM sc
  LEFT JOIN rk ON rk.x = sc.x4 AND rk.y = sc.y4
  LEFT JOIN ck ON ck.x = sc.x3 AND ck.y = sc.y3
 CROSS JOIN LATERAL public.rpg_map_town_make(sc.x, sc.y, sc.city, sc.town, sc.rolls, ck.kind, rk.kind) m
 WHERE p_level >= 3;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, kind text, name text, people integer, tx bigint, ty bigint, r double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block of the City grid or finer that lie inside a village, town or city (rpg_map_towns; step 8): the
-- middle of the cell is no farther from the middle of the settlement than r times 1 + its three waves at that angle (shape:
-- size x cos(bumps x angle + turn)). The one home of what ground a settlement covers: rpg_map_cells makes those cells
-- town ground (unless they are water or belong to a place), the Maps tab names them by it. tx, ty = the middle of the
-- settlement, in world squares, counted the way the block counts. A coarser grid has none: there a settlement is a mark.
WITH lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     t AS MATERIALIZED (SELECT * FROM public.rpg_map_towns(p_level, p_x0, p_y0, p_cols, p_rows, NULL) t WHERE t.kind IS NOT NULL AND p_level >= 5)
SELECT DISTINCT ON (gx, gy) gx, gy, t.id, t.kind, t.name, t.people, t.x, t.y, t.r
  FROM t CROSS JOIN lad
 CROSS JOIN LATERAL (SELECT t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS far) f
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor((t.x - f.far) / lad.cell)::integer), least(p_x0 + p_cols - 1, floor((t.x + f.far) / lad.cell)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((t.y - f.far) / lad.cell)::integer), least(p_y0 + p_rows - 1, floor((t.y + f.far) / lad.cell)::integer)) AS gy
 CROSS JOIN LATERAL (SELECT (gx + 0.5) * lad.cell - t.x AS dx, (gy + 0.5) * lad.cell - t.y AS dy) d
 CROSS JOIN LATERAL (SELECT atan2(d.dy, d.dx) AS a) a
 WHERE sqrt(d.dx * d.dx + d.dy * d.dy)
       <= t.r * (1 + t.shape[1] * cos(2 * a.a + t.shape[2]) + t.shape[3] * cos(3 * a.a + t.shape[4]) + t.shape[5] * cos(4 * a.a + t.shape[6]))
 ORDER BY gx, gy, t.id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_entry(p_id text, p_kind text, p_name text, p_people integer, p_x bigint, p_y bigint, p_r double precision,
                                                     p_level integer, p_gx0 bigint, p_gy0 bigint, p_gx1 bigint, p_gy1 bigint, p_listed boolean,
                                                     p_ground text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How the Maps tab is told about a village, town or city (rpg_map_view_block; step 8), the one home of it, the way it is
-- told about a place card: id, name, kind and icon (its map symbol: village, town or city), color, level (its kind in
-- words), size (its people and how far across it is), ground (its streets in words: p_ground, rpg_map_band_text of town, worked out once by the caller), view = the
-- City grid that holds its middle (where it opens), listed = it belongs on the list of the grid, spot = where it sits on the
-- grid p_level whose block runs from square p_gx0, p_gy0 up to p_gx1, p_gy1: its middle from the top-left corner and
-- its width and height, in thousandths of a cell, or nothing when its middle is off the block.
SELECT jsonb_strip_nulls(jsonb_build_object(
         'id', p_id, 'name', p_name, 'kind', p_kind, 'icon', p_kind, 'color', '#B08A5E', 'level', initcap(p_kind),
         'size', 'about ' || to_char(p_people, 'FM999,999') || ' people, ' || public.rpg_map_length_text(round(2 * p_r)::numeric) || ' across',
         'ground', p_ground,
         'view', '5-' || mod(mod(floor(p_x::double precision / c.cell)::bigint, c.across) + c.across, c.across)::text || '-' || floor(p_y::double precision / c.cell)::bigint::text,
         'listed', p_listed,
         'spot', CASE WHEN p_x >= p_gx0 AND p_x < p_gx1 AND p_y >= p_gy0 AND p_y < p_gy1
                      THEN jsonb_build_array(((p_x - p_gx0) * 1000 + g.cell / 2) / g.cell, ((p_y - p_gy0) * 1000 + g.cell / 2) / g.cell,
                                             (round(2 * p_r)::bigint * 1000 + g.cell / 2) / g.cell, (round(2 * p_r)::bigint * 1000 + g.cell / 2) / g.cell) END))
  FROM (SELECT l.cell::bigint AS cell, l.across::bigint AS across FROM public.rpg_map_ladder() l WHERE l.level = 4) c
 CROSS JOIN (SELECT l.cell::bigint AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) g;
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
--   town       its center lies inside a village, town or city (rpg_map_town_cells; step 8): their streets and
--              yards. Only the City grid and finer: a coarser grid marks them instead (rpg_map_view_block).
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
     tc AS MATERIALIZED (
       -- the cells inside a village, town or city (rpg_map_town_cells): the City grid and finer
       SELECT t.x, t.y FROM public.rpg_map_town_cells(p_level, p_x0, p_y0, p_cols, p_rows) t WHERE p_level >= 5),
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
            WHEN tc.x IS NOT NULL THEN 'town'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN tc ON tc.x = g.gx AND tc.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim, tc.x
 ORDER BY g.gy, g.gx;
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
       -- the villages, towns and cities marked on this grid (the Country grid its cities, the Region grid all three),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows,
                                              CASE WHEN v_l.level IN (3, 4) THEN (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) FROM c) END) t
          WHERE v_l.level IN (3, 4) AND t.kind IS NOT NULL),
       tm AS (SELECT floor(tw.x::double precision / v_l.cell)::integer AS x, floor(tw.y::double precision / v_l.cell)::integer AS y,
                     jsonb_agg(tw.id ORDER BY tw.id) AS ids
                FROM tw GROUP BY 1, 2),
       -- the words for their streets, once
       gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
       -- the City grid and finer: the cells of their ground
       tg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) t WHERE v_l.level >= 5),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, CASE WHEN c.kind = 'town' THEN tg.id END AS town
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
                   WHERE cl.seen AND cl.town IS NOT NULL) q)
    INTO v_cells, v_towns;

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
                     WHERE d.seen AND d.town IS NOT NULL) q)
      INTO v_detail, v_dtowns
      FROM ln;
  END IF;

  -- a village, town or city both marked on the grid and drawn in its detail is told once
  IF v_dtowns IS NOT NULL THEN
    SELECT jsonb_agg(q.e ORDER BY q.n) INTO v_towns
      FROM (SELECT DISTINCT ON (e.value ->> 'id') e.value AS e, e.n
              FROM jsonb_array_elements(coalesce(v_towns, '[]'::jsonb) || v_dtowns) WITH ORDINALITY AS e(value, n)
             ORDER BY e.value ->> 'id', e.n) q;
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
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;
UPDATE public.rpg_rules SET body = replace(body,
'Wading across a 10 m stream, 9 squares, takes about 72 ticks, 12 seconds.*',
'Wading across a 10 m stream, 9 squares, takes about 72 ticks, 12 seconds.*

People live in villages, towns and cities, spread over the land the way farming country was in medieval England. In good open land there is a village of 100 to 400 people about every 2 miles, a market town of 500 to 5,000 about every 9, and a city of 8,000 to 16,000 about every 110. Forest holds half as many, hills a little more than half; pine forest, jungle, mountains and swamp few; desert and tundra almost none; snow and ice none; and none stand inside a haunt or any other place with ground of its own. The Country grid shows the cities, the Region grid all three, and closer grids their streets and yards, +0% to +10% time a square like open land.
*A village of 250 people covers about 12 hectares, a quarter of a mile across. A town of 2,000 is about a third of a mile across, a city of 12,000 about two thirds of a mile.*'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('People live in villages' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'open land and grassy plains +0% to +10%; desert',
'open land, grassy plains and the streets and yards of villages, towns and cities +0% to +10%; desert'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('streets and yards of villages' IN body) = 0;

