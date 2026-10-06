-- roleplaying map step 12a: great cities (Peter 2026-10-04 13:44: the world map should have some more landmarks and huge
-- cities). Settings map_great_city_*; new rpg_map_great_lattice, rpg_map_great; rpg_map_town_make (great cities, their
-- names), rpg_map_town_sites (Continent grid sites, reach), rpg_map_towns (Continent grid), rpg_map_town_at and
-- rpg_map_roads (a great city is a city to the roads), rpg_map_town_entry (words, people), rpg_map_icons, rpg_map_view_block
-- (Continent grid marks; road runs end where the line meets a cell not shown), rpg_map_buildings; rule card world_map.

-- step 12a: great cities (Peter 2026-10-04 13:44: the world map should have some more landmarks and huge cities)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label
  FROM (VALUES ('map_great_city_lattice', 373248::numeric, 'Settlements: each square this many squares across (259 miles, 3 x 3 city squares, about the size of England and Wales) picks one of its city sites for a great city'),
               ('map_great_city_share', 0.6, 'Great cities: share of great-city sites that hold one where the land of their Continent cell is open (as often as a city grows at its site; England and Wales c. 1300 had one, London)'),
               ('map_great_city_people_low', 20000, 'Great cities: fewest people'),
               ('map_great_city_people_high', 200000, 'Great cities: most people (Paris c. 1328, the largest city of Latin Europe)'),
               ('map_great_city_density', 230, 'Great cities: people a hectare (cities grow denser as they grow: their ground rises with people to the power 0.77, Cesaretti et al. 2016, so one of 70,000 is about 1.5 times as crowded as one of 11,000)'),
               ('map_house_plot_great_city_low', 1, 'Houses: narrowest great-city plot, perches wide'),
               ('map_house_plot_great_city_high', 1.5, 'Houses: widest great-city plot, perches wide'),
               ('map_house_storeys_great_city_low', 3, 'Houses: fewest storeys in a great-city house'),
               ('map_house_storeys_great_city_high', 4, 'Houses: most storeys in a great-city house (the tall houses of the biggest medieval cities, Schofield 1994)')) AS v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = v.key);

CREATE OR REPLACE FUNCTION public.rpg_map_great_lattice()
 RETURNS TABLE(seed integer, lc bigint, lg bigint, ng bigint, ag bigint)
 LANGUAGE sql
 STABLE
AS $function$
-- The numbers of the lattice great cities stand on (step 12a), the one home of them: seed = the map seed; lc = squares
-- across a city square (map_city_lattice, 124,416); lg = squares across a great-city square (map_great_city_lattice,
-- 373,248: 3 x 3 city squares, 259 miles); ng = city squares across one (3); ag = great-city squares round the world
-- (96). Plain SQL with nothing set of its own, so a caller reads it as part of its own query (rpg_map_town_make asks
-- for it at every city site that could grow a great city); its callers run with the rights of their owner.
SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = g.agency_id AND s.key = 'map_seed')::integer,
       c.value::bigint, g.value::bigint, g.value::bigint / c.value::bigint, w.span::bigint / g.value::bigint
  FROM public.rpg_settings g
  JOIN public.rpg_settings c ON c.agency_id = g.agency_id AND c.key = 'map_city_lattice'
 CROSS JOIN (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1) w
 WHERE g.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND g.key = 'map_great_city_lattice';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_great(p_gx bigint, p_gy bigint, p_seed integer, p_ng bigint, p_ag bigint)
 RETURNS TABLE(cx bigint, cy bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The city square whose city site may hold the great city of a great-city square (step 12a): the one home of that
-- pick. Each square of map_great_city_lattice (p_ng x p_ng city squares, 3 x 3) picks one of its city squares by two
-- fixed-seed rolls (rpg_map_roll part 11, layers 1151 and 1152 at the great-city square, its column counted round the
-- world: p_ag great-city squares round); the great city stands at the city site of that city square (rpg_map_city,
-- rpg_map_hub), so a great city grows where a city could, never beside one. Whether it grows is rpg_map_town_make.
SELECT p_gx * p_ng + mod(k.k, p_ng), p_gy * p_ng + k.k / p_ng
  FROM (SELECT mod((public.rpg_map_roll(p_seed, 1151, mod(mod(p_gx, p_ag) + p_ag, p_ag)::integer, p_gy::integer) - 1) * 100
                   + public.rpg_map_roll(p_seed, 1152, mod(mod(p_gx, p_ag) + p_ag, p_ag)::integer, p_gy::integer) - 1, p_ng * p_ng) AS k) k;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_make(p_x bigint, p_y bigint, p_city boolean, p_town boolean, p_rolls integer[], p_country text, p_region text)
 RETURNS TABLE(kind text, name text, people integer, r double precision, shape double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What grows at a site (rpg_map_town_sites), the one home of it (step 8): a city, a town, a village or nothing, how
-- many people live there, how far it reaches, its name and how its edge wanders. Worked out when asked, never stored.
-- A great city (step 12a; Peter 2026-10-04 13:44: huge cities) is decided first: the city site of the city square its
-- great-city square picked (rpg_map_great; map_great_city_lattice, 3 x 3 city squares, 259 miles, about the size of
-- England and Wales, which c. 1300 had one city far above the rest, London) grows one on the same roll a city takes,
-- under map_great_city_share times how well the ground of its Continent cell is settled, counted twice: once for the
-- site to hold a city at all, once for the land round it to feed a great one (open land 0.6, forest 0.15, hills 0.22,
-- mountains or swamp 1 in 75; the cell read through rpg_map_kinds and kept for the transaction), and only where its
-- own square is dry land (rpg_map_heights_on at the battle grid), so no great city stands in the sea. Else the site
-- may still grow a city.
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
     -- a great city: this is the city site its great-city square picked, and the roll could grow one on the best ground
     gc AS MATERIALIZED (
       SELECT q.x2, q.y2, q.wx, floor(q.cx::double precision / q.ng)::bigint AS gx, floor(q.cy::double precision / q.ng)::bigint AS gy
              FROM (SELECT gl.seed, gl.ng, gl.ag, floor(p_x::double precision / gl.lc)::bigint AS cx, floor(p_y::double precision / gl.lc)::bigint AS cy,
                           floor(p_x::double precision / c.c2)::integer AS x2, floor(p_y::double precision / c.c2)::integer AS y2,
                           mod(mod(p_x, c.world) + c.world, c.world)::integer AS wx
                      FROM public.rpg_map_great_lattice() gl
                     CROSS JOIN (SELECT max(w.cell) FILTER (WHERE w.level = 2)::bigint AS c2, max(w.span) FILTER (WHERE w.level = 1)::bigint AS world FROM public.rpg_map_ladder() w) c
                     WHERE p_city AND (p_rolls[1] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_great_city_share')) q
             CROSS JOIN LATERAL public.rpg_map_great(floor(q.cx::double precision / q.ng)::bigint, floor(q.cy::double precision / q.ng)::bigint, q.seed, q.ng, q.ag) g
             WHERE g.cx = q.cx AND g.cy = q.cy),
     -- then the ground of its Continent cell, then dry land under its own middle
     g2 AS MATERIALIZED (SELECT gc.wx FROM gc CROSS JOIN LATERAL public.rpg_map_kinds(2, gc.x2, gc.y2, 1, 1) k2
             WHERE (p_rolls[1] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_great_city_share')
                                              * power(coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || k2.kind), 0), 2)),
     g3 AS MATERIALIZED (SELECT 1 FROM g2 CROSS JOIN LATERAL public.rpg_map_heights_on(7, 1, g2.wx, p_y::integer, 1, 1) h
             WHERE h.height >= (SELECT st.value FROM st WHERE st.key = 'map_sea_level')),
     k AS MATERIALIZED (SELECT CASE WHEN EXISTS (SELECT 1 FROM g3) THEN 'great_city'
                       WHEN p_city AND (p_rolls[1] - 0.5) / 100
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
                   -- a great city (step 12a) names itself after a river, as Exeter, Tynemouth and Doncaster did: 64 rivers
                   -- of England, none of them a first part of the names above, so no village, town or city shares a
                   -- great city name
                   ARRAY['Avon', 'Alde', 'Arun', 'Axe', 'Bure', 'Brue', 'Calder', 'Cam', 'Char', 'Colne', 'Dart', 'Deben',
                         'Dove', 'Eden', 'Esk', 'Exe', 'Fowey', 'Frome', 'Glen', 'Hodder', 'Humber', 'Irwell', 'Isis', 'Itchen',
                         'Kennet', 'Lea', 'Lune', 'Medway', 'Mersey', 'Nene', 'Ouse', 'Parrett', 'Ribble', 'Roding', 'Rother', 'Severn',
                         'Soar', 'Stour', 'Swale', 'Tamar', 'Taw', 'Tees', 'Teme', 'Test', 'Thame', 'Torridge', 'Trent', 'Tyne',
                         'Ure', 'Usk', 'Wear', 'Welland', 'Wey', 'Wharfe', 'Witham', 'Wye', 'Yare', 'Yeo', 'Aire', 'Derwent',
                         'Kent', 'Mole', 'Otter', 'Lugg'] AS rivers,
                   CASE WHEN rr.kind = 'great_city' THEN ARRAY['chester', 'cester', 'caster', 'minster', 'mouth', 'borough', 'bury', 'ford']
                        WHEN rr.kind = 'city' THEN ARRAY['bury', 'chester', 'minster', 'caster', 'ford', 'bridge', 'ham', 'borough', 'wick']
                        WHEN rr.kind = 'town' THEN ARRAY['ford', 'bridge', 'ham', 'ton', 'bury', 'wick', 'field', 'stow', 'borough', 'worth']
                        WHEN p_region IN ('forest', 'pine', 'jungle') THEN ARRAY['wood', 'hurst', 'den', 'ley', 'holt', 'field', 'ridge']
                        WHEN p_region IN ('hills', 'mountains') THEN ARRAY['don', 'combe', 'ley', 'hill', 'low', 'dale', 'side']
                        WHEN p_region = 'swamp' THEN ARRAY['mere', 'fen', 'ey', 'marsh', 'holm']
                        WHEN p_region IN ('desert', 'tundra') THEN ARRAY['well', 'stead', 'by', 'cote']
                        ELSE ARRAY['ton', 'ham', 'stead', 'thorpe', 'by', 'wick', 'cote', 'worth', 'field', 'ley', 'well', 'brook', 'ford'] END AS ends
              FROM rr),
     pn AS (SELECT CASE WHEN g.gx IS NULL THEN nm.firsts[1 + mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, cardinality(nm.firsts))]
                        -- a great city: its river by where its great-city square sits in each block of 4 x 4 of them
                        -- (1,036 miles) and a roll for which of four, so no two great cities of such a block share one
                        ELSE nm.rivers[1 + mod(mod(g.gx, 4) + 4, 4) + 4 * mod(mod(g.gy, 4) + 4, 4) + 16 * mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, 4)] END AS a,
                   nm.ends[1 + mod((p_rolls[7] - 1) * 100 + p_rolls[8] - 1, cardinality(nm.ends))] AS b
              FROM nm LEFT JOIN (SELECT gc.gx, gc.gy FROM gc CROSS JOIN rr WHERE rr.kind = 'great_city') g ON true)
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
$function$

;

CREATE OR REPLACE FUNCTION public.rpg_map_town_sites(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, x bigint, y bigint, city boolean, town boolean, rolls integer[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a village, town or city could stand on a block of any grid, worked out when asked and never stored: the one
-- home of where settlements sit (step 8; Peter 2026-10-03 17:28: more towns). The sites follow central place theory
-- (Christaller 1933): each village square (map_village_lattice, 2,592 squares, 1.8 miles) holds one site (rpg_map_site,
-- at rpg_map_site_spot), every square of map_town_lattice (4 x 4 village squares, 7.2 miles) picks one of its sites for a
-- town (rpg_map_hub), and every square of map_city_lattice (12 x 12 town squares, 86 miles) picks one of its town sites
-- for a city (rpg_map_city): a town grows at the site of a village and a city at the site of a town, so they never
-- crowd each other. Every square of map_great_city_lattice (3 x 3 city squares, 259 miles) picks one of its city sites
-- for a great city (rpg_map_great; step 12a).
-- Whether anything grows there, and what, is rpg_map_town_make.
-- id = site-<column>-<row> of its village square, the same seen from any block; x, y = the site in world squares from
-- 0, counted the way the block counts (a block past the east or west end of the world keeps its own count); city,
-- town = the site of a city or of a town; rolls = its fixed-seed d100s (rpg_map_site_rolls).
-- What a block gets: the World grid nothing; the Continent grid the city site each great-city square picked whose
-- middle lies on it (it shows only great cities); the Country grid the city sites whose middle lies on it
-- (it shows only cities and great cities); the Region grid every site whose middle lies on it; a finer grid every site whose biggest
-- possible ground (rpg_map_town_radius of the most people of each kind, its edge out by map_town_edge) reaches it.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     cfg AS MATERIALIZED (
       SELECT q.*, greatest(q.rv, q.rt, q.rc) AS reach
         FROM (SELECT t.*, l.cell::bigint AS cell,
                      -- how far the ground of the biggest village, town and city can reach from its site
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('village', (SELECT st.value FROM st WHERE st.key = 'map_village_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rv,
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('town', (SELECT st.value FROM st WHERE st.key = 'map_town_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rt,
                      -- a city site may grow a great city (step 12a): the bigger of the two
                      CASE WHEN p_level >= 5 THEN ceil(greatest(public.rpg_map_town_radius('city', (SELECT st.value FROM st WHERE st.key = 'map_city_people_high')::integer),
                                                                public.rpg_map_town_radius('great_city', (SELECT st.value FROM st WHERE st.key = 'map_great_city_people_high')::integer))
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rc
                 FROM public.rpg_map_lattice() t CROSS JOIN public.rpg_map_ladder() l
                WHERE l.level = p_level AND p_level >= 2) q),
     -- the squares of the world the block reaches, x from x0 up to x1, y from y0 up to y1 (not including x1, y1)
     bx AS (SELECT p_x0::bigint * cfg.cell - cfg.reach AS x0, (p_x0 + p_cols)::bigint * cfg.cell + cfg.reach AS x1,
                   greatest(p_y0::bigint * cfg.cell - cfg.reach, 0) AS y0, least((p_y0 + p_rows)::bigint * cfg.cell + cfg.reach, cfg.down) AS y1
              FROM cfg),
     -- the Country grid: each city square the block reaches, the town square it picks (rpg_map_city), then the village
     -- square that town square picks (rpg_map_hub)
     cc AS (SELECT h.vx, h.vy
              FROM cfg CROSS JOIN bx
             CROSS JOIN LATERAL generate_series(floor(bx.x0::double precision / cfg.lc)::bigint, floor((bx.x1 - 1)::double precision / cfg.lc)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(bx.y0::double precision / cfg.lc)::bigint, floor((bx.y1 - 1)::double precision / cfg.lc)::bigint) AS b
             CROSS JOIN LATERAL public.rpg_map_city(a, b, cfg.seed, cfg.nt, cfg.ac) t
             CROSS JOIN LATERAL public.rpg_map_hub(t.tx, t.ty, cfg.seed, cfg.nv, cfg.at) h
             WHERE p_level = 3),
     -- the Continent grid (step 12a): each great-city square the block reaches, the city square it picks
     -- (rpg_map_great), the town square that city square picks (rpg_map_city), then its village square (rpg_map_hub)
     gc AS (SELECT h.vx, h.vy
              FROM cfg CROSS JOIN bx CROSS JOIN public.rpg_map_great_lattice() gl
             CROSS JOIN LATERAL generate_series(floor(bx.x0::double precision / gl.lg)::bigint, floor((bx.x1 - 1)::double precision / gl.lg)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(bx.y0::double precision / gl.lg)::bigint, floor((bx.y1 - 1)::double precision / gl.lg)::bigint) AS b
             CROSS JOIN LATERAL public.rpg_map_great(a, b, cfg.seed, gl.ng, gl.ag) g
             CROSS JOIN LATERAL public.rpg_map_city(g.cx, g.cy, cfg.seed, cfg.nt, cfg.ac) t
             CROSS JOIN LATERAL public.rpg_map_hub(t.tx, t.ty, cfg.seed, cfg.nv, cfg.at) h
             WHERE p_level = 2),
     -- every village square the block reaches (the Region grid and finer), or on the Country grid only the sites the
     -- city squares picked
     vs AS (SELECT a AS vx, b AS vy
              FROM cfg CROSS JOIN bx
             CROSS JOIN LATERAL generate_series(floor(bx.x0::double precision / cfg.lv)::bigint, floor((bx.x1 - 1)::double precision / cfg.lv)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(bx.y0::double precision / cfg.lv)::bigint, floor((bx.y1 - 1)::double precision / cfg.lv)::bigint) AS b
             WHERE p_level >= 4
            UNION ALL
            SELECT cc.vx, cc.vy FROM cc
            UNION ALL
            SELECT gc.vx, gc.vy FROM gc),
     q AS MATERIALIZED (
       SELECT v.vx, v.vy, s.vw, s.x, s.y, s.town, s.city
         FROM vs v CROSS JOIN cfg
        CROSS JOIN LATERAL public.rpg_map_site(v.vx, v.vy, cfg.seed, cfg.lv, cfg.jit, cfg.nv, cfg.nt, cfg.av, cfg.at, cfg.ac) s)
SELECT 'site-' || q.vw || '-' || q.vy, q.x, q.y, q.city, q.town, public.rpg_map_site_rolls(q.vw, q.vy, cfg.seed)
  FROM q CROSS JOIN cfg
 -- a site only a village can grow at reaches no farther than the biggest village, a town site than the biggest town
 CROSS JOIN LATERAL (SELECT CASE WHEN q.city THEN cfg.reach WHEN q.town THEN greatest(cfg.rt, cfg.rv) ELSE cfg.rv END AS r) r
 WHERE q.x >= p_x0::bigint * cfg.cell - r.r AND q.x < (p_x0 + p_cols)::bigint * cfg.cell + r.r
   AND q.y >= p_y0::bigint * cfg.cell - r.r AND q.y < (p_y0 + p_rows)::bigint * cfg.cell + r.r
   AND (p_level > 3 OR q.city);
$function$

;

CREATE OR REPLACE FUNCTION public.rpg_map_towns(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_kinds jsonb)
 RETURNS TABLE(id text, kind text, name text, people integer, x bigint, y bigint, r double precision, shape double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The villages, towns and cities a block of any grid shows (step 8): its sites (rpg_map_town_sites) and what grows at
-- each (rpg_map_town_make), the one way they are read. The Country grid shows its cities, the Region grid all three,
-- a finer grid every one whose ground reaches it. A site is decided by the ground of the cell it stands in, a city by
-- its Country cell and a town or a village by its Region cell (rpg_map_cells, read through rpg_map_kinds, which keeps
-- them for the rest of the transaction), so the same site grows the same thing
-- seen from any grid. p_kinds = the kinds of the cells of this very block when the caller already has them ("x,y":
-- kind, as rpg_map_cells counts them), so a Country or Region grid is not worked out twice; else nothing.
-- The Continent grid shows its great cities (step 12a), each decided by the Continent cell under it: rpg_map_town_make
-- reads that cell through rpg_map_kinds, so a Continent block given its own kinds keeps them for the transaction
-- (rpg.kinds2) before any site is decided, and no cell of it is worked out twice.
WITH s AS MATERIALIZED (SELECT * FROM public.rpg_map_town_sites(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the Continent grid: its own kinds kept first (sc reads this before any site is decided)
     k2 AS MATERIALIZED (
       SELECT CASE WHEN p_level = 2 AND p_kinds IS NOT NULL
                   THEN set_config('rpg.kinds2', (coalesce(nullif(current_setting('rpg.kinds2', true), ''), '{}')::jsonb || p_kinds)::text, true) END AS kept),
     lc AS (SELECT (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 3)::bigint AS c3,
                   (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 4)::bigint AS c4),
     sc AS MATERIALIZED (
       SELECT s.*, floor(s.x::double precision / lc.c3)::integer AS x3, floor(s.y::double precision / lc.c3)::integer AS y3,
              floor(s.x::double precision / lc.c4)::integer AS x4, floor(s.y::double precision / lc.c4)::integer AS y4
         FROM s CROSS JOIN lc CROSS JOIN k2),
     -- the Region cells under the sites (the Region grid and finer), read once as a block
     rb AS (SELECT min(sc.x4) AS x0, min(sc.y4) AS y0, max(sc.x4) - min(sc.x4) + 1 AS cols, max(sc.y4) - min(sc.y4) + 1 AS rows
              FROM sc WHERE p_level >= 4 AND NOT (p_level = 4 AND p_kinds IS NOT NULL) HAVING count(*) > 0),
     rk AS MATERIALIZED (
       SELECT c.x, c.y, c.kind FROM rb CROSS JOIN LATERAL public.rpg_map_kinds(4, rb.x0, rb.y0, rb.cols, rb.rows) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 4),
     -- the Country cell under the site of each city
     ck AS MATERIALIZED (
       SELECT d.x3 AS x, d.y3 AS y, c.kind
         FROM (SELECT DISTINCT sc.x3, sc.y3 FROM sc WHERE sc.city AND p_level >= 3 AND NOT (p_level = 3 AND p_kinds IS NOT NULL)) d
        CROSS JOIN LATERAL public.rpg_map_kinds(3, d.x3, d.y3, 1, 1) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 3)
SELECT sc.id, m.kind, m.name, m.people, sc.x, sc.y, m.r, m.shape
  FROM sc
  LEFT JOIN rk ON rk.x = sc.x4 AND rk.y = sc.y4
  LEFT JOIN ck ON ck.x = sc.x3 AND ck.y = sc.y3
 CROSS JOIN LATERAL public.rpg_map_town_make(sc.x, sc.y, sc.city, sc.town, sc.rolls, ck.kind, rk.kind) m
 WHERE p_level >= 2;
$function$

;

CREATE OR REPLACE FUNCTION public.rpg_map_town_at(p_vx bigint[], p_vy bigint[], p_kinds jsonb DEFAULT NULL::jsonb, p_level integer DEFAULT NULL::integer, p_cities boolean DEFAULT false, p_any boolean DEFAULT false)
 RETURNS TABLE(vx bigint, vy bigint, kind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether the site of each given village square holds a town or a city (step 8b: the roads between towns and cities
-- meet there), decided the way rpg_map_towns decides it (rpg_map_town_make on the ground of its Country cell for a city,
-- of its Region cell for a town) but reading as little of the map as it can: no cell at all for a site whose rolls
-- make no town or city even on the best ground (three town sites in ten); the cells the caller already has (p_kinds,
-- "x,y": kind on the grid p_level, 3 or 4, as rpg_map_cells counts them); else the cells it needs (rpg_map_kinds, kept
-- for the rest of the transaction), four or more close together in one block (at most 30 by 30), else one at a time. kind = city, town or nothing (a village, or no one); a great city (step 12a) is a city to the roads.
-- p_cities: only whether a city stands there (no Region cell is read; a town reads as nothing). p_any: villages too
-- (kind village; a site that can hold no one even on the best ground, one in eight, is not read).
#variable_conflict use_column
DECLARE
  c record; v_c3 bigint; v_c4 bigint; v_cs double precision; v_ts double precision; v_vs double precision;
  v_nx integer[]; v_ny integer[]; v_n integer; v_bx0 integer; v_by0 integer; v_bx1 integer; v_by1 integer;
  v_rk jsonb := '{}'; v_ck jsonb := '{}';
BEGIN
  SELECT * INTO c FROM public.rpg_map_lattice();
  SELECT l.cell INTO v_c3 FROM public.rpg_map_ladder() l WHERE l.level = 3;
  SELECT l.cell INTO v_c4 FROM public.rpg_map_ladder() l WHERE l.level = 4;
  SELECT s.value INTO v_cs FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_city_share';
  SELECT s.value INTO v_ts FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_share';
  SELECT s.value INTO v_vs FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_village_share';
  IF p_level = 4 AND p_kinds IS NOT NULL THEN v_rk := p_kinds; END IF;
  IF p_level = 3 AND p_kinds IS NOT NULL THEN v_ck := p_kinds; END IF;

  -- the Region cells wanted: under every site that could hold a town or a city on the best ground, not already known
  IF NOT p_cities THEN
    WITH s AS (
           SELECT DISTINCT floor(x.x::double precision / v_c4)::integer AS rx, floor(x.y::double precision / v_c4)::integer AS ry
             FROM unnest(p_vx, p_vy) AS u(vx, vy)
            CROSS JOIN LATERAL public.rpg_map_site(u.vx, u.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
            CROSS JOIN LATERAL (SELECT public.rpg_map_site_rolls(x.vw, u.vy, c.seed) AS r) r
            WHERE (x.city AND (r.r[1] - 0.5) / 100 < v_cs OR x.town AND (r.r[2] - 0.5) / 100 < v_ts OR p_any AND (r.r[3] - 0.5) / 100 < v_vs)
              AND NOT v_rk ? (floor(x.x::double precision / v_c4)::integer || ',' || floor(x.y::double precision / v_c4)::integer))
    SELECT array_agg(s.rx), array_agg(s.ry), count(*), min(s.rx), min(s.ry), max(s.rx), max(s.ry)
      INTO v_nx, v_ny, v_n, v_bx0, v_by0, v_bx1, v_by1 FROM s;
    IF v_n BETWEEN 1 AND 3 OR (v_n > 3 AND (v_bx1 - v_bx0 + 1) * (v_by1 - v_by0 + 1) > 900) THEN
      SELECT v_rk || coalesce(jsonb_object_agg(k.x || ',' || k.y, k.kind), '{}') INTO v_rk
        FROM unnest(v_nx, v_ny) AS u(x, y) CROSS JOIN LATERAL public.rpg_map_kinds(4, u.x, u.y, 1, 1) k;
    ELSIF v_n > 3 THEN
      SELECT v_rk || coalesce(jsonb_object_agg(k.x || ',' || k.y, k.kind), '{}') INTO v_rk
        FROM public.rpg_map_kinds(4, v_bx0, v_by0, v_bx1 - v_bx0 + 1, v_by1 - v_by0 + 1) k;
    END IF;
  END IF;

  -- the Country cells wanted: under every site that could hold a city, one at a time (cities stand far apart)
  WITH s AS (
         SELECT DISTINCT floor(x.x::double precision / v_c3)::integer AS cx, floor(x.y::double precision / v_c3)::integer AS cy
           FROM unnest(p_vx, p_vy) AS u(vx, vy)
          CROSS JOIN LATERAL public.rpg_map_site(u.vx, u.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
          WHERE x.city AND ((public.rpg_map_site_rolls(x.vw, u.vy, c.seed))[1] - 0.5) / 100 < v_cs
            AND NOT v_ck ? (floor(x.x::double precision / v_c3)::integer || ',' || floor(x.y::double precision / v_c3)::integer))
  SELECT v_ck || coalesce(jsonb_object_agg(k.x || ',' || k.y, k.kind), '{}') INTO v_ck
    FROM s CROSS JOIN LATERAL public.rpg_map_kinds(3, s.cx, s.cy, 1, 1) k;

  RETURN QUERY
  SELECT u.vx, u.vy, CASE WHEN m.kind IN ('city', 'great_city') THEN 'city' WHEN (m.kind = 'town' AND NOT p_cities) OR (m.kind = 'village' AND p_any) THEN m.kind END
    FROM unnest(p_vx, p_vy) AS u(vx, vy)
   CROSS JOIN LATERAL public.rpg_map_site(u.vx, u.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
   CROSS JOIN LATERAL (SELECT public.rpg_map_site_rolls(x.vw, u.vy, c.seed) AS r) r
    LEFT JOIN LATERAL public.rpg_map_town_make(x.x, x.y, x.city, x.town, r.r,
                                               v_ck ->> (floor(x.x::double precision / v_c3)::integer || ',' || floor(x.y::double precision / v_c3)::integer),
                                               CASE WHEN NOT p_cities THEN v_rk ->> (floor(x.x::double precision / v_c4)::integer || ',' || floor(x.y::double precision / v_c4)::integer) END) m
      ON x.city AND (r.r[1] - 0.5) / 100 < v_cs OR (NOT p_cities AND x.town AND (r.r[2] - 0.5) / 100 < v_ts) OR (p_any AND (r.r[3] - 0.5) / 100 < v_vs);
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
  v_key text; v_cache jsonb; v_rows jsonb; v_c6 integer;
BEGIN
  IF p_level < 3 OR coalesce(p_what, 0) = 0 THEN RETURN; END IF;
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
  RETURN QUERY SELECT (e.v ->> 0)::integer, (e.v ->> 1)::double precision, (e.v ->> 2)::double precision, (e.v ->> 3)::double precision, (e.v ->> 4)::double precision, e.v ->> 5, e.v ->> 6
                 FROM jsonb_array_elements(v_rows) AS e(v);
END;
$function$

;

CREATE OR REPLACE FUNCTION public.rpg_map_town_entry(p_id text, p_kind text, p_name text, p_people integer, p_x bigint, p_y bigint, p_r double precision, p_level integer, p_gx0 bigint, p_gy0 bigint, p_gx1 bigint, p_gy1 bigint, p_listed boolean, p_ground text)
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
         'id', p_id, 'name', p_name, 'kind', p_kind, 'icon', p_kind, 'color', '#B08A5E', 'level', CASE WHEN p_kind = 'great_city' THEN 'Great city' ELSE initcap(p_kind) END, 'people', p_people,
         'size', 'about ' || to_char(p_people, 'FM999,999') || ' people, ' || public.rpg_map_length_text(round(2 * p_r)::numeric) || ' across',
         'ground', p_ground,
         'view', '5-' || mod(mod(floor(p_x::double precision / c.cell)::bigint, c.across) + c.across, c.across)::text || '-' || floor(p_y::double precision / c.cell)::bigint::text,
         'listed', p_listed,
         'spot', CASE WHEN p_x >= p_gx0 AND p_x < p_gx1 AND p_y >= p_gy0 AND p_y < p_gy1
                      THEN jsonb_build_array(((p_x - p_gx0) * 1000 + g.cell / 2) / g.cell, ((p_y - p_gy0) * 1000 + g.cell / 2) / g.cell,
                                             (round(2 * p_r)::bigint * 1000 + g.cell / 2) / g.cell, (round(2 * p_r)::bigint * 1000 + g.cell / 2) / g.cell) END))
  FROM (SELECT l.cell::bigint AS cell, l.across::bigint AS across FROM public.rpg_map_ladder() l WHERE l.level = 4) c
 CROSS JOIN (SELECT l.cell::bigint AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) g;
$function$

;

CREATE OR REPLACE FUNCTION public.rpg_map_icons()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp) are symbols too. So are
-- a town and a city (step 8: the villages, towns and cities that grow on the land, rpg_map_towns), and a great city
-- (step 12a).
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'town', 'city', 'great_city'];
$function$

;

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
  v_rivs      jsonb;
  v_drivs     jsonb;
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

  -- the rivers are read a little past the block on the grids that draw crossings (step 11): a bridge over the water
  -- of the District grid may reach three cells in, over the water of the City grid two, a crossing of a line one
  v_rm := CASE WHEN v_l.level = 6 THEN 3 WHEN v_l.level = 5 THEN 2 WHEN v_l.level = 4 THEN 1 ELSE 0 END;
  v_ry0 := greatest(v_y0 - v_rm, 0);
  v_ry1 := least(v_y0 + v_rows + v_rm, v_l.down);
  -- the cells, read once for the villages, towns and cities on them (step 8) and for the picture
  WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows)),
       -- the kinds of the cells of a Continent, Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (2, 3, 4)),
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
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))),
       -- the rivers near every cell (rpg_map_rivers), read once: for the lines drawn and for the crossings (step 11),
       -- with a margin round the block where a crossing just outside it may still reach in
       rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) r),
       -- the battle grid: the water under the roads and the fords (step 11), where it has roads or water
       wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_flow(v_l.level, v_x0, v_y0, v_cols, v_rows) w
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       fd AS MATERIALIZED (SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif,
                CASE WHEN c.kind IN ('road', 'pass') AND wt.depth > 0 THEN 'bridge' WHEN c.kind = 'water' AND fd.x IS NOT NULL THEN 'ford' END AS cross
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
           LEFT JOIN fd ON fd.x = c.x AND fd.y = c.y
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
                   -- the battle grid: a bridge over the water, or a ford through it (step 11)
                   'cross', CASE WHEN cl.seen THEN cl.cross END,
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
            FROM rva r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs;

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
    v_rm := CASE WHEN v_l.level + 1 = 6 THEN 3 WHEN v_l.level + 1 = 5 THEN 2 WHEN v_l.level + 1 = 4 THEN 1 ELSE 0 END;
    v_ry0 := greatest(v_y0 * v_sub - v_rm, 0);
    v_ry1 := least(v_y0 * v_sub + v_dr + v_rm, (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1));
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
         rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub - v_rm, v_ry0, v_dc + 2 * v_rm, v_ry1 - v_ry0) r),
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
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
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width');
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
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rv WHERE rv.x = g.x0 + floor(q.ox)::integer AND rv.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rv r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rv)),
         xs AS (
           SELECT cx.*, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1),
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
    'crossings', coalesce(v_cross, '[]'::jsonb),
    'houses', coalesce(v_houses, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$

;

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
                  max(st.v) FILTER (WHERE st.key IN ('map_house_plot_town_high', 'map_house_plot_city_high', 'map_house_plot_great_city_high')) AS plot_hi,
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
$function$

;

-- the rule card (step 12a): great cities
UPDATE public.rpg_rules
   SET body = replace(replace(replace(replace(replace(body,
                'a market town of 500 to 5,000 about every 9, and a city of 8,000 to 16,000 about every 110.',
                'a market town of 500 to 5,000 about every 9, a city of 8,000 to 16,000 about every 110, and a great city of 20,000 to 200,000 about every 330 (London had perhaps 80,000 people c. 1300, Paris about 200,000 in 1328).'),
                'and none stand inside a haunt or any other place with ground of its own.',
                'and none stand inside a haunt or any other place with ground of its own. A great city needs good land twice over, for its site and for the farms that feed it, so forest has a quarter as many, hills about a third, and rough country almost none; it never stands in the sea.'),
                'The Country grid shows the cities, the Region grid all three, and closer grids',
                'The Continent grid shows the great cities, the Country grid the cities too, the Region grid all four, and closer grids'),
                'a city house has two or three.',
                'a city house has two or three, a great city house three or four.'),
                'a city of 12,000 about two thirds of a mile.*',
                'a city of 12,000 about two thirds of a mile. A great city of 100,000, at 230 people a hectare (a bigger city is more crowded), covers 435 hectares, about a mile and a half across.*'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('and a city of 8,000 to 16,000 about every 110.' IN body) > 0
   AND position('The Country grid shows the cities, the Region grid all three' IN body) > 0
   AND position('a city house has two or three.' IN body) > 0
   AND position('a city of 12,000 about two thirds of a mile.*' IN body) > 0
   AND position('and none stand inside a haunt or any other place with ground of its own.' IN body) > 0
   AND position('great city' IN body) = 0;

