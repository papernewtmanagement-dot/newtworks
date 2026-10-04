-- Step 8b (Peter 2026-10-03 17:28 "roads between places"; 2026-10-04 11:18 "Go"): highways, roads and lanes between
-- the villages, towns and cities of step 8a, worked out from the map when asked and never stored, the way the
-- settlements are. Every road runs straight from one place to the next, as the medieval network did (the Gough Map,
-- c. 1360: about 600 places joined by 455 stretches, most under 10 km). A highway, 6.5 m wide (the average of some 500
-- principal Roman roads), runs from each city to its neighbouring cities by way of the town sites between (Christaller
-- 1933, the traffic principle); a road, 4.9 m (two carts pass, Leges Henrici Primi), from each town to its neighbouring
-- towns; a lane, 2.4 m (the 8 Roman feet of the Twelve Tables), from each village toward its market town, to the first
-- place with people on the way. Neighbours: the squares beside, and a corner square when it passes the Gabriel test
-- (Gabriel and Sokal 1969). No road crosses a place of rough ground of its own (Old Forest, the Fog); open places are
-- crossed. Roads cross rivers and lakes (a bridge, a ford or a ferry; Harrison 2004), never the sea.
-- Time: a square of road +0% to +10% (Soule and Goldman 1972: blacktop 1.0, dirt road 1.1); a mountain road keeps 3/5
-- of the time of mountains, +80% to +260% (Tobler 1993: off a path walking takes 5/3 as long); snow and ice stay as
-- they are. A walk goes the way with the fewest steps when each step off a road counts 5/3, planning up to
-- map_road_plan town squares (14.4 miles) ahead and stopping where its plan ends when the roads lead on.
-- The Country grid draws its highways, the Region grid down to the District grid all three; the battle grid has road
-- and mountain road as ground of its own.
-- New: rpg_map_lattice, rpg_map_hub, rpg_map_city, rpg_map_site_spot, rpg_map_site, rpg_map_site_rolls (the site
-- lattice of step 8a in pieces the roads share; rpg_map_town_sites gives the same sites as before), rpg_map_kinds (cell
-- kinds kept for the transaction), rpg_map_town_at, rpg_map_seg_oval, rpg_map_roads, rpg_map_road_cells,
-- rpg_map_route_path, rpg_map_path_at, rpg_map_road_path. Changed in place: rpg_map_town_sites, rpg_map_towns,
-- rpg_map_grounds (road, pass), rpg_map_band (pass), rpg_map_cells (road ground on the battle grid), rpg_map_route (now
-- one leg of rpg_map_route_path, same result), rpg_map_walk (along the roads), rpg_map_view_block (roads). Seven
-- settings; the cards The World Map and Walking and The Board and Moving. No drops, no table changes.

INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_road_penalty', 0::numeric, 'Roads: least percent of time a square of a road adds (paved: Soule and Goldman 1972 count a blacktop road 1.0)'),
               ('map_road_penalty_high', 10, 'Roads: most percent of time a square of a road adds (a dirt road is about 1.1 times a paved one, Soule and Goldman 1972)'),
               ('map_road_keep', 0.6, 'Roads: share of the time on a road compared with off it on the same ground (off a path walking takes 5/3 as long, Tobler 1993); a mountain road keeps this share of the time of mountains, and a walk keeps to the roads unless they are more than 5/3 as long as the straight way'),
               ('map_road_1_width', 5.8, 'Highways: squares wide (6.5 m: the average of some 500 principal Roman roads)'),
               ('map_road_2_width', 4.4, 'Roads: squares wide (4.9 m: two carts pass, Leges Henrici Primi)'),
               ('map_road_3_width', 2.1, 'Lanes: squares wide (2.4 m: the 8 Roman feet of the Twelve Tables, one cart)'),
               ('map_road_plan', 2, 'Roads: how many town squares (7.2 miles each) a walk looks ahead each way when it plans its way along the roads')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_lattice()
 RETURNS TABLE(seed integer, lv bigint, lt bigint, lc bigint, jit double precision, nv bigint, nt bigint, av bigint, at bigint, ac bigint, world bigint, down bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The numbers of the lattice villages, towns and cities stand on (step 8), read once: the map seed; lv, lt, lc = squares
-- across a village, town and city square (map_village_lattice 2,592, map_town_lattice 10,368, map_city_lattice
-- 124,416); jit = the middle share of its square a site sits in (map_town_jitter); nv = village squares across a town
-- square (4), nt = town squares across a city square (12); av, at, ac = village, town and city squares round the world;
-- world, down = squares round the world and from pole to pole. Read by rpg_map_town_sites and the roads.
SELECT q.seed, q.lv, q.lt, q.lc, q.jit, q.lt / q.lv, q.lc / q.lt, q.world / q.lv, q.world / q.lt, q.world / q.lc, q.world, q.world / 2
  FROM (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_village_lattice')::bigint AS lv,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_lattice')::bigint AS lt,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_city_lattice')::bigint AS lc,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_jitter')::double precision AS jit,
               (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)::bigint AS world) q;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_hub(p_tx bigint, p_ty bigint, p_seed integer, p_nv bigint, p_at bigint)
 RETURNS TABLE(vx bigint, vy bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The village square whose site holds the town of a town square (step 8): the one home of that pick. Each square of
-- map_town_lattice (p_nv x p_nv village squares, 4 x 4) picks one of its sites by two fixed-seed rolls (rpg_map_roll part
-- 11, layers 1111 and 1112 at the town square, its column counted round the world: p_at town squares round). A town
-- square past the east or west end of the world keeps its own count in the answer. The lattice numbers come from
-- rpg_map_lattice; plain SQL, so the caller reads it as part of its own query.
SELECT p_tx * p_nv + mod(m.m, p_nv), p_ty * p_nv + m.m / p_nv
  FROM (SELECT mod((public.rpg_map_roll(p_seed, 1111, mod(mod(p_tx, p_at) + p_at, p_at)::integer, p_ty::integer) - 1) * 100
                   + public.rpg_map_roll(p_seed, 1112, mod(mod(p_tx, p_at) + p_at, p_at)::integer, p_ty::integer) - 1, p_nv * p_nv) AS m) m;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_city(p_cx bigint, p_cy bigint, p_seed integer, p_nt bigint, p_ac bigint)
 RETURNS TABLE(tx bigint, ty bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The town square whose town site holds the city of a city square (step 8): the one home of that pick. Each square of
-- map_city_lattice (p_nt x p_nt town squares, 12 x 12) picks one of its town squares by two fixed-seed rolls
-- (rpg_map_roll part 11, layers 1121 and 1122 at the city square, its column counted round the world: p_ac city
-- squares round); the city stands at the town site of that town square (rpg_map_hub).
SELECT p_cx * p_nt + mod(k.k, p_nt), p_cy * p_nt + k.k / p_nt
  FROM (SELECT mod((public.rpg_map_roll(p_seed, 1121, mod(mod(p_cx, p_ac) + p_ac, p_ac)::integer, p_cy::integer) - 1) * 100
                   + public.rpg_map_roll(p_seed, 1122, mod(mod(p_cx, p_ac) + p_ac, p_ac)::integer, p_cy::integer) - 1, p_nt * p_nt) AS k) k;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_site_spot(p_vx bigint, p_vy bigint, p_vw bigint, p_seed integer, p_lv bigint, p_jit double precision)
 RETURNS TABLE(x bigint, y bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Where the site of a village square stands (step 8): the one home of it. The land is cut into squares of
-- map_village_lattice (p_lv, 2,592 squares, 1.8 miles) and each holds one site, at a steady spot within the middle
-- map_town_jitter (p_jit, 0.6) of it each way (rolls part 11, layers 1101 and 1102 at the square, its column counted
-- round the world: p_vw), so two sites stand at least 1,037 squares (0.72 miles) apart. x, y = the spot in world squares
-- from 0, counted the way p_vx counts (a square past the east or west end keeps its own count).
SELECT p_vx * p_lv + floor(p_lv * ((1 - p_jit) / 2 + p_jit * (public.rpg_map_roll(p_seed, 1101, p_vw::integer, p_vy::integer) - 0.5) / 100))::bigint,
       p_vy * p_lv + floor(p_lv * ((1 - p_jit) / 2 + p_jit * (public.rpg_map_roll(p_seed, 1102, p_vw::integer, p_vy::integer) - 0.5) / 100))::bigint;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_site(p_vx bigint, p_vy bigint, p_seed integer, p_lv bigint, p_jit double precision, p_nv bigint, p_nt bigint, p_av bigint, p_at bigint, p_ac bigint)
 RETURNS TABLE(vw bigint, x bigint, y bigint, town boolean, city boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The site of one village square (step 8): the one home of what a site is. vw = its column counted round the world (its
-- id is site-<vw>-<row>); x, y = where it stands (rpg_map_site_spot); town = its town square picked it (rpg_map_hub);
-- city = it is the town site of the town square its city square picked (rpg_map_city). The lattice numbers come from
-- rpg_map_lattice. What grows there is rpg_map_town_make.
SELECT w.vw, sp.x, sp.y, p.vx = p_vx AND p.vy = p_vy, p.vx = p_vx AND p.vy = p_vy AND w.tx = k.tx AND w.ty = k.ty
  FROM (SELECT mod(mod(p_vx, p_av) + p_av, p_av) AS vw, floor(p_vx::double precision / p_nv)::bigint AS tx, floor(p_vy::double precision / p_nv)::bigint AS ty) w
 CROSS JOIN LATERAL public.rpg_map_site_spot(p_vx, p_vy, w.vw, p_seed, p_lv, p_jit) sp
 CROSS JOIN LATERAL public.rpg_map_hub(w.tx, w.ty, p_seed, p_nv, p_at) p
 CROSS JOIN LATERAL public.rpg_map_city(floor(w.tx::double precision / p_nt)::bigint, floor(w.ty::double precision / p_nt)::bigint, p_seed, p_nt, p_ac) k;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_site_rolls(p_vw bigint, p_vy bigint, p_seed integer)
 RETURNS integer[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The fixed-seed d100s of a site (step 8; rpg_map_roll part 11, layers 1131 to 1144 at its village square, its column
-- counted round the world): whether a city, a town and a village grow there, how many people, its name (4) and how its
-- edge wanders (6). The one home of them; what they mean is rpg_map_town_make.
SELECT ARRAY(SELECT public.rpg_map_roll(p_seed, 1130 + n, p_vw::integer, p_vy::integer) FROM generate_series(1, 14) AS n ORDER BY n);
$function$;

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
-- crowd each other.
-- Whether anything grows there, and what, is rpg_map_town_make.
-- id = site-<column>-<row> of its village square, the same seen from any block; x, y = the site in world squares from
-- 0, counted the way the block counts (a block past the east or west end of the world keeps its own count); city,
-- town = the site of a city or of a town; rolls = its fixed-seed d100s (rpg_map_site_rolls).
-- What a block gets: the World and Continent grids nothing; the Country grid the city sites whose middle lies on it
-- (it shows only cities); the Region grid every site whose middle lies on it; a finer grid every site whose biggest
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
                      CASE WHEN p_level >= 5 THEN ceil(public.rpg_map_town_radius('city', (SELECT st.value FROM st WHERE st.key = 'map_city_people_high')::integer)
                                                       * (1 + (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision))::bigint ELSE 0 END AS rc
                 FROM public.rpg_map_lattice() t CROSS JOIN public.rpg_map_ladder() l
                WHERE l.level = p_level AND p_level >= 3) q),
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
       SELECT v.vx, v.vy, s.vw, s.x, s.y, s.town, s.city
         FROM vs v CROSS JOIN cfg
        CROSS JOIN LATERAL public.rpg_map_site(v.vx, v.vy, cfg.seed, cfg.lv, cfg.jit, cfg.nv, cfg.nt, cfg.av, cfg.at, cfg.ac) s)
SELECT 'site-' || q.vw || '-' || q.vy, q.x, q.y, q.city, q.town, public.rpg_map_site_rolls(q.vw, q.vy, cfg.seed)
  FROM q CROSS JOIN cfg
 -- a site only a village can grow at reaches no farther than the biggest village, a town site than the biggest town
 CROSS JOIN LATERAL (SELECT CASE WHEN q.city THEN cfg.reach WHEN q.town THEN greatest(cfg.rt, cfg.rv) ELSE cfg.rv END AS r) r
 WHERE q.x >= p_x0::bigint * cfg.cell - r.r AND q.x < (p_x0 + p_cols)::bigint * cfg.cell + r.r
   AND q.y >= p_y0::bigint * cfg.cell - r.r AND q.y < (p_y0 + p_rows)::bigint * cfg.cell + r.r
   AND (p_level <> 3 OR q.city);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_kinds(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The kind of every cell of a block of one grid, as rpg_map_cells gives it, kept for the rest of the transaction once
-- worked out (step 8b). What grows at a site and whether a road runs to it is decided by the Country or Region cell
-- under it (rpg_map_towns, rpg_map_town_at), and one read of the map (a walk, a fight board, a view) asks for the same
-- few cells again and again, each asked alone about as dear as a block of thirty. Nothing is stored: the kinds live in a
-- setting of the transaction (rpg.kinds3, rpg.kinds4 and so on, "x,y": kind) and are gone when it ends. A block with any
-- cell not yet known is worked out whole.
DECLARE
  v_key text := 'rpg.kinds' || p_level;
  v_c jsonb;
BEGIN
  v_c := coalesce(nullif(current_setting(v_key, true), ''), '{}')::jsonb;
  IF EXISTS (SELECT 1 FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy
              WHERE NOT v_c ? (gx || ',' || gy)) THEN
    SELECT v_c || coalesce(jsonb_object_agg(c.x || ',' || c.y, c.kind), '{}') INTO v_c
      FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows) c;
    PERFORM set_config(v_key, v_c::text, true);
  END IF;
  RETURN QUERY
  SELECT gx, gy, v_c ->> (gx || ',' || gy)
    FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy;
END;
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
-- its Country cell and a town or a village by its Region cell (rpg_map_cells, read through rpg_map_kinds, which keeps
-- them for the rest of the transaction), so the same site grows the same thing
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
       SELECT c.x, c.y, c.kind FROM rb CROSS JOIN LATERAL public.rpg_map_kinds(4, rb.x0, rb.y0, rb.cols, rb.rows) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 4),
     -- the Country cell under the site of each city
     ck AS MATERIALIZED (
       SELECT d.x3 AS x, d.y3 AS y, c.kind
         FROM (SELECT DISTINCT sc.x3, sc.y3 FROM sc WHERE sc.city AND NOT (p_level = 3 AND p_kinds IS NOT NULL)) d
        CROSS JOIN LATERAL public.rpg_map_kinds(3, d.x3, d.y3, 1, 1) c
       UNION ALL
       SELECT split_part(e.key, ',', 1)::integer, split_part(e.key, ',', 2)::integer, e.value
         FROM jsonb_each_text(p_kinds) e WHERE p_level = 3)
SELECT sc.id, m.kind, m.name, m.people, sc.x, sc.y, m.r, m.shape
  FROM sc
  LEFT JOIN rk ON rk.x = sc.x4 AND rk.y = sc.y4
  LEFT JOIN ck ON ck.x = sc.x3 AND ck.y = sc.y3
 CROSS JOIN LATERAL public.rpg_map_town_make(sc.x, sc.y, sc.city, sc.town, sc.rolls, ck.kind, rk.kind) m
 WHERE p_level >= 3;
$function$
;

CREATE OR REPLACE FUNCTION public.rpg_map_town_at(p_vx bigint[], p_vy bigint[], p_kinds jsonb DEFAULT NULL, p_level integer DEFAULT NULL, p_cities boolean DEFAULT false, p_any boolean DEFAULT false)
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
-- for the rest of the transaction), four or more close together in one block (at most 30 by 30), else one at a time. kind = city, town or nothing (a village, or no one).
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
  SELECT u.vx, u.vy, CASE WHEN m.kind = 'city' OR (m.kind = 'town' AND NOT p_cities) OR (m.kind = 'village' AND p_any) THEN m.kind END
    FROM unnest(p_vx, p_vy) AS u(vx, vy)
   CROSS JOIN LATERAL public.rpg_map_site(u.vx, u.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
   CROSS JOIN LATERAL (SELECT public.rpg_map_site_rolls(x.vw, u.vy, c.seed) AS r) r
    LEFT JOIN LATERAL public.rpg_map_town_make(x.x, x.y, x.city, x.town, r.r,
                                               v_ck ->> (floor(x.x::double precision / v_c3)::integer || ',' || floor(x.y::double precision / v_c3)::integer),
                                               CASE WHEN NOT p_cities THEN v_rk ->> (floor(x.x::double precision / v_c4)::integer || ',' || floor(x.y::double precision / v_c4)::integer) END) m
      ON x.city AND (r.r[1] - 0.5) / 100 < v_cs OR (NOT p_cities AND x.town AND (r.r[2] - 0.5) / 100 < v_ts) OR (p_any AND (r.r[3] - 0.5) / 100 < v_vs);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_seg_oval(p_ax double precision, p_ay double precision, p_bx double precision, p_by double precision, p_cx double precision, p_cy double precision, p_w double precision, p_h double precision, p_world double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Whether a straight stretch from a to b passes inside an oval p_w wide and p_h tall round p_cx, p_cy (step 8b: a road
-- never crosses a place of rough ground). The oval is taken as the copy nearest the middle of the stretch, since the
-- map wraps east to west (p_world squares round). Stretched so the oval is a circle of 1, the stretch passes inside
-- when its point nearest the middle is less than 1 from it.
SELECT power(q.u0 + q.t * q.du, 2) + power(q.v0 + q.t * q.dv, 2) < 1
  FROM (SELECT p.u0, p.v0, p.du, p.dv,
               CASE WHEN p.du * p.du + p.dv * p.dv = 0 THEN 0
                    ELSE least(greatest(-(p.u0 * p.du + p.v0 * p.dv) / (p.du * p.du + p.dv * p.dv), 0), 1) END AS t
          FROM (SELECT (p_ax - m.cx) / (p_w / 2) AS u0, (p_ay - p_cy) / (p_h / 2) AS v0,
                       (p_bx - p_ax) / (p_w / 2) AS du, (p_by - p_ay) / (p_h / 2) AS dv
                  FROM (SELECT p_cx + p_world * floor(((p_ax + p_bx) / 2 - p_cx) / p_world + 0.5) AS cx) m) p) q;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_roads(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_what integer DEFAULT 7, p_towns jsonb DEFAULT NULL, p_pad double precision DEFAULT 0)
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
-- grid, and the roads and lanes only from the Region grid down. Every stretch that comes within p_pad squares, plus
-- half the widest road, of the block, once: class, its two ends a and b in world squares counted the way the block
-- counts (a block past the east or west end of the world keeps its own count), and the places at its ends
-- (site-<column>-<row> of a site, or the id of a place card). p_towns = what grows at the sites inside this very block
-- (id: city, town or village, as rpg_map_towns reads them; a site inside it that is not named has no one) when the
-- caller has it (Country grid: its cities; Region grid: all three), so nothing inside the block is read twice; the
-- ends outside it are read only when the other end of their stretch has the town or city it needs.
#variable_conflict use_column
DECLARE
  c record; v_cell bigint; v_c4 bigint; v_high integer; v_pad double precision; v_k bigint; v_cs double precision; v_ts double precision;
  v_x0 double precision; v_y0 double precision; v_x1 double precision; v_y1 double precision;
  v_bx0 bigint; v_by0 bigint; v_bx1 bigint; v_by1 bigint; v_ek jsonb;
  o_cls integer[] := '{}'; o_ax double precision[] := '{}'; o_ay double precision[] := '{}'; o_bx double precision[] := '{}';
  o_by double precision[] := '{}'; o_a text[] := '{}'; o_b text[] := '{}';
  h_pvx bigint[]; h_pvy bigint[]; h_qvx bigint[]; h_qvy bigint[]; h_ax double precision[]; h_ay double precision[];
  h_bx double precision[]; h_by double precision[]; h_a text[]; h_b text[];
  l_x double precision[]; l_y double precision[]; l_vx bigint[]; l_vy bigint[]; l_id text[]; l_k0 integer[]; v_kind jsonb := '{}';
  r_x double precision[]; r_y double precision[]; r_w double precision[]; r_h double precision[];
BEGIN
  IF p_level < 3 OR coalesce(p_what, 0) = 0 THEN RETURN; END IF;
  SELECT * INTO c FROM public.rpg_map_lattice();
  SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  SELECT l.cell INTO v_c4 FROM public.rpg_map_ladder() l WHERE l.level = 4;
  v_k := c.lt / v_c4;
  SELECT s.value INTO v_high FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_penalty_high';
  SELECT coalesce(p_pad, 0) + max(s.value) / 2 INTO v_pad FROM public.rpg_settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width');
  v_x0 := p_x0::double precision * v_cell - v_pad; v_x1 := (p_x0 + p_cols)::double precision * v_cell + v_pad;
  v_y0 := p_y0::double precision * v_cell - v_pad; v_y1 := (p_y0 + p_rows)::double precision * v_cell + v_pad;
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
    IF h_pvx IS NOT NULL THEN
      -- only between two cities that are there: first what is known without reading the map (a roll that makes no city
      -- even on the best ground; a site inside the block, from p_towns), then the other ends of what is left
      WITH cu AS (SELECT DISTINCT u.vx, u.vy FROM unnest(h_pvx || h_qvx, h_pvy || h_qvy) AS u(vx, vy))
      SELECT coalesce(jsonb_object_agg(cu.vx || ',' || cu.vy,
                        CASE WHEN ((public.rpg_map_site_rolls(x.vw, cu.vy, c.seed))[1] - 0.5) / 100 >= v_cs THEN 'no'
                             ELSE coalesce(p_towns ->> ('site-' || x.vw || '-' || cu.vy), 'no') END)
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
    IF h_pvx IS NOT NULL THEN
      -- only between two towns or cities that are there, known first as for the highways
      WITH cu AS (SELECT DISTINCT u.vx, u.vy FROM unnest(h_pvx || h_qvx, h_pvy || h_qvy) AS u(vx, vy)),
           cr AS (SELECT cu.vx, cu.vy, x.vw, x.x, x.y,
                         NOT (x.city AND (r.r[1] - 0.5) / 100 < v_cs) AND NOT (x.town AND (r.r[2] - 0.5) / 100 < v_ts) AS none,
                         p_towns IS NOT NULL AND x.x >= v_bx0 AND x.x < v_bx1 AND x.y >= v_by0 AND x.y < v_by1 AS known
                    FROM cu CROSS JOIN LATERAL public.rpg_map_site(cu.vx, cu.vy, c.seed, c.lv, c.jit, c.nv, c.nt, c.av, c.at, c.ac) x
                   CROSS JOIN LATERAL (SELECT public.rpg_map_site_rolls(x.vw, cu.vy, c.seed) AS r) r)
      SELECT coalesce(jsonb_object_agg(cr.vx || ',' || cr.vy,
                        CASE WHEN cr.none THEN 'no' WHEN p_towns ->> ('site-' || cr.vw || '-' || cr.vy) IN ('town', 'city') THEN 'town' ELSE 'no' END)
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
           SELECT DISTINCT w.x, w.y, w.vx, w.vy, w.id, w.k0
             FROM way w
            CROSS JOIN LATERAL generate_series(w.k0, greatest(abs(w.hx - w.vx), abs(w.hy - w.vy))::integer) AS k
             JOIN ss t ON t.vx = w.vx + sign(w.hx - w.vx)::bigint * least(k, abs(w.hx - w.vx))
                      AND t.vy = w.vy + sign(w.hy - w.vy)::bigint * least(k, abs(w.hy - w.vy))
            WHERE public.rpg_seg_box(w.x, w.y, t.x, t.y, v_x0, v_y0, v_x1, v_y1))
    SELECT array_agg(nr.x), array_agg(nr.y), array_agg(nr.vx), array_agg(nr.vy), array_agg(nr.id), array_agg(nr.k0)
      INTO l_x, l_y, l_vx, l_vy, l_id, l_k0 FROM nr;
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
      SELECT o_cls || coalesce(array_agg(3), '{}'), o_ax || coalesce(array_agg(ln.ax), '{}'), o_ay || coalesce(array_agg(ln.ay), '{}'),
             o_bx || coalesce(array_agg(ln.bx), '{}'), o_by || coalesce(array_agg(ln.by), '{}'), o_a || coalesce(array_agg(ln.a), '{}'), o_b || coalesce(array_agg(ln.b), '{}')
        INTO o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b
        FROM ln
       WHERE public.rpg_seg_box(ln.ax, ln.ay, ln.bx, ln.by, v_x0, v_y0, v_x1, v_y1);
    END IF;
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (least(o.a, o.b), greatest(o.a, o.b)) o.cls, o.ax, o.ay, o.bx, o.by, o.a, o.b
    FROM unnest(o_cls, o_ax, o_ay, o_bx, o_by, o_a, o_b) AS o(cls, ax, ay, bx, by, a, b)
   WHERE NOT EXISTS (SELECT 1 FROM unnest(r_x, r_y, r_w, r_h) AS r(x, y, w, h)
                      WHERE public.rpg_map_seg_oval(o.ax, o.ay, o.bx, o.by, r.x, r.y, r.w, r.h, c.world::double precision))
   ORDER BY least(o.a, o.b), greatest(o.a, o.b), o.cls;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, class integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block that a road runs over (step 8b): the middle of the cell lies within half the width of the road
-- (map_road_<size>_width) of the line of a stretch of road (rpg_map_roads, the one home of where roads run). Only the
-- battle grid has cells this small (a highway is 6.5 m wide, a square 1.1 m); rpg_map_cells makes them road ground.
-- class = the biggest road there (1 highway, 2 road, 3 lane).
WITH lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     w AS (SELECT substr(s.key, 10, 1)::integer AS class, s.value::double precision / 2 AS half FROM public.rpg_settings s
            WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width')),
     lg AS MATERIALIZED (
       SELECT r.class, r.ax, r.ay, r.bx, r.by, w.half
         FROM public.rpg_map_roads(p_level, p_x0, p_y0, p_cols, p_rows, 7, NULL, 0) r JOIN w ON w.class = r.class)
SELECT gx, gy, min(lg.class)
  FROM lg CROSS JOIN lad
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor((least(lg.ax, lg.bx) - lg.half) / lad.cell)::integer),
                                    least(p_x0 + p_cols - 1, floor((greatest(lg.ax, lg.bx) + lg.half) / lad.cell)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((least(lg.ay, lg.by) - lg.half) / lad.cell)::integer),
                                    least(p_y0 + p_rows - 1, floor((greatest(lg.ay, lg.by) + lg.half) / lad.cell)::integer)) AS gy
 -- how far the middle of the cell lies from the stretch: from its nearest point
 CROSS JOIN LATERAL (SELECT (gx + 0.5) * lad.cell - lg.ax AS px, (gy + 0.5) * lad.cell - lg.ay AS py, lg.bx - lg.ax AS dx, lg.by - lg.ay AS dy) v
 CROSS JOIN LATERAL (SELECT CASE WHEN v.dx * v.dx + v.dy * v.dy = 0 THEN 0
                                 ELSE least(greatest((v.px * v.dx + v.py * v.dy) / (v.dx * v.dx + v.dy * v.dy), 0), 1) END AS t) t
 WHERE power(v.px - t.t * v.dx, 2) + power(v.py - t.t * v.dy, 2) <= lg.half * lg.half
 GROUP BY gx, gy;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; rivers and
-- lakes; villages, towns and cities, step 8; roads, step 8b: a road, and a road over mountains, whose range is that of
-- mountains kept to map_road_keep, rpg_map_band), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
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
               (15, 'town', 'Village, town or city', 'n', 'map_town_penalty', false),
               (16, 'road', 'Road', 'r', 'map_road_penalty', false),
               (17, 'pass', 'Mountain road', 'a', NULL, false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$
;

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
-- (rpg_map_wade_pct: 10 to 190); a square of it goes by its depth, not by a roll. A road over mountains (pass, step 8b)
-- keeps map_road_keep (3/5) of the time of mountains: walking off a path takes 5/3 as long as on one (Tobler 1993), so
-- mountains of +200% to +500% (3 to 6 times the time) are +80% to +260% on their roads. thicket = the percent of a thicket,
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
            WHERE p_kind = 'water'
           UNION ALL
           SELECT round((SELECT st.value FROM st WHERE st.key = 'map_road_keep') * (100 + (SELECT st.value FROM st WHERE st.key = 'map_mountain_penalty')) - 100)::integer,
                  round((SELECT st.value FROM st WHERE st.key = 'map_road_keep') * (100 + (SELECT st.value FROM st WHERE st.key = 'map_mountain_penalty_high')) - 100)::integer,
                  false, false
            WHERE p_kind = 'pass')
SELECT b.low, b.high,
       CASE WHEN b.thick AND b.high < t.pct THEN t.pct END,
       CASE WHEN b.thick AND b.high < t.pct THEN t.share ELSE 0 END,
       b.forest
  FROM b CROSS JOIN t;
$function$
;

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
--   road       the battle grid only: a highway, road or lane runs over the square (rpg_map_road_cells; step 8b), the
--   pass       middle of the square within half the width of the road from its line: road, or pass where the ground under
--              it is mountains (a road over a pass keeps its climb). A road over snow and ice is the snow and ice; where
--              a road meets a river or a lake it crosses it (a bridge, a ford or a ferry: road, ahead of the water); the
--              sea stops it. Coarser grids draw roads as lines instead.
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
     rd AS MATERIALIZED (
       -- the squares a road runs over (rpg_map_road_cells): the battle grid only
       SELECT r.x, r.y FROM public.rpg_map_road_cells(p_level, p_x0, p_y0, p_cols, p_rows) r WHERE p_level = 7),
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
            WHEN rd.x IS NOT NULL AND wt.depth > 0 THEN 'road'
            WHEN wt.depth >= cfg.swim THEN 'deep'
            WHEN wt.depth > 0 THEN 'water'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            WHEN tc.x IS NOT NULL THEN 'town'
            WHEN rd.x IS NOT NULL AND g.kind = 'mountains' THEN 'pass'
            WHEN rd.x IS NOT NULL AND g.kind <> 'ice' THEN 'road'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN tc ON tc.x = g.gx AND tc.y = g.gy
  LEFT JOIN rd ON rd.x = g.gx AND rd.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim, tc.x, rd.x
 ORDER BY g.gy, g.gx;
$function$
;

CREATE OR REPLACE FUNCTION public.rpg_map_route_path(p_xs integer[], p_ys integer[], p_max integer DEFAULT NULL::integer, p_from integer DEFAULT 1)
 RETURNS TABLE(k_from integer, k_to integer, kind text, place_id uuid, level integer, leg integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground under a walk, read a stretch at a time and never square by square (20 miles is 28,779 squares): the one
-- home of how a walk is read. A walk is a path of straight legs (rpg_map_line) from one point of p_xs, p_ys to the next
-- (one leg for a straight walk; a walk along the roads goes from place to place, step 8b, rpg_map_road_path), its
-- steps counted on from leg to leg. It covers the steps p_from to p_max (what the walking day can hold; a closer look
-- at one stretch). The ground is read on the finest grid of the ladder where those steps cross at most 72 cells: up
-- to 72 squares on the battle grid itself, up to 864 squares (0.6 mile) in 44-foot runs, up to 10,368 (7.2 miles) in
-- 528-foot runs, past that in 1.2-mile runs. One row a run: the steps k_from to k_to (step 1 is the first square
-- entered) all in one cell of that grid on one leg, its kind and place as rpg_map_cells gives them, the grid read and
-- the leg (1 = from the first point to the second). The cells are asked for a block at a time (the walk where it
-- crosses one grid of the level above), never one by one.
WITH lg AS MATERIALIZED (
       SELECT i AS leg, p_xs[i] AS x0, p_ys[i] AS y0, p_xs[i + 1] AS x1, p_ys[i + 1] AS y1, l.dx::bigint AS dx, l.dy::bigint AS dy, l.steps::bigint AS steps
         FROM generate_series(1, cardinality(p_xs) - 1) AS i
        CROSS JOIN LATERAL public.rpg_map_line(p_xs[i], p_ys[i], p_xs[i + 1], p_ys[i + 1]) l),
     cu AS MATERIALIZED (
       SELECT lg.*, (sum(lg.steps) OVER (ORDER BY lg.leg) - lg.steps)::bigint AS c0, (sum(lg.steps) OVER ())::bigint AS total FROM lg),
     wk AS MATERIALIZED (
       SELECT greatest(coalesce(p_from, 1), 1)::bigint AS k0, least(max(cu.total), greatest(coalesce(p_max, max(cu.total)), 0))::bigint AS k_end FROM cu),
     lv AS MATERIALIZED (
       SELECT w.level, w.cell::bigint AS cell
         FROM public.rpg_map_ladder() w CROSS JOIN wk
        WHERE wk.k_end - wk.k0 + 1 <= 72::bigint * w.cell
        ORDER BY w.level DESC LIMIT 1),
     -- the share of each leg of the steps asked for, counted on that leg
     ln AS MATERIALIZED (
       SELECT cu.leg, cu.x0, cu.y0, cu.x1, cu.y1, cu.dx, cu.dy, cu.steps, cu.c0,
              greatest(wk.k0 - cu.c0, 1) AS k0, least(wk.k_end - cu.c0, cu.steps) AS k_end
         FROM cu CROSS JOIN wk
        WHERE greatest(wk.k0 - cu.c0, 1) <= least(wk.k_end - cu.c0, cu.steps)),
     ax AS (SELECT ln.leg, ln.x0::bigint AS a, ln.dx AS d, ln.steps,
                   ln.x0 + floor((2::numeric * ln.k0 * ln.dx + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint AS b,
                   ln.x0 + floor((2::numeric * ln.k_end * ln.dx + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint AS e FROM ln
            UNION ALL
            SELECT ln.leg, ln.y0::bigint, ln.dy, ln.steps,
                   ln.y0 + floor((2::numeric * ln.k0 * ln.dy + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint,
                   ln.y0 + floor((2::numeric * ln.k_end * ln.dy + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint FROM ln),
     bd AS (
       -- the first step in each new cell along one axis: p(k) = a + floor((2kd + S) / 2S) first reaches t = m x cell
       -- going up at k = ceil(S(2(t - a) - 1) / 2d), and first drops below t going down at floor(S(2(t - a) - 1) / 2d) + 1
       SELECT ax.leg, CASE WHEN ax.d > 0 THEN ceil(ax.steps::numeric * (2 * (m * lv.cell - ax.a) - 1) / (2 * ax.d))
                           ELSE floor(ax.steps::numeric * (2 * (m * lv.cell - ax.a) - 1) / (2 * ax.d)) + 1 END::bigint AS k
         FROM ax CROSS JOIN lv
        CROSS JOIN LATERAL generate_series(CASE WHEN ax.d > 0 THEN floor(ax.b::numeric / lv.cell)::bigint + 1 ELSE floor(ax.e::numeric / lv.cell)::bigint + 1 END,
                                           CASE WHEN ax.d > 0 THEN floor(ax.e::numeric / lv.cell)::bigint ELSE floor(ax.b::numeric / lv.cell)::bigint END) AS m
        WHERE ax.d <> 0),
     st AS (SELECT DISTINCT q.leg, q.k
              FROM (SELECT ln.leg, ln.k0::bigint AS k FROM ln UNION ALL SELECT bd.leg, bd.k FROM bd) q
              JOIN ln ON ln.leg = q.leg
             WHERE q.k BETWEEN ln.k0 AND ln.k_end),
     rn AS (SELECT st.leg, st.k AS k_from, coalesce(lead(st.k) OVER (PARTITION BY st.leg ORDER BY st.k) - 1, ln.k_end) AS k_to
              FROM st JOIN ln ON ln.leg = st.leg),
     ce AS MATERIALIZED (
       SELECT rn.leg, (rn.k_from + ln.c0)::integer AS k_from, (rn.k_to + ln.c0)::integer AS k_to, (s.x / lv.cell)::integer AS cx, (s.y / lv.cell)::integer AS cy
         FROM rn JOIN ln ON ln.leg = rn.leg CROSS JOIN lv
        CROSS JOIN LATERAL public.rpg_map_line_at(ln.x0, ln.y0, ln.x1, ln.y1, rn.k_from::integer) s),
     bl AS (SELECT min(ce.cx) AS x0, max(ce.cx) AS x1, min(ce.cy) AS y0, max(ce.cy) AS y1 FROM ce GROUP BY ce.cx / 12, ce.cy / 12),
     kd AS MATERIALIZED (
       SELECT c.x, c.y, c.kind, c.place_id
         FROM bl CROSS JOIN lv CROSS JOIN LATERAL public.rpg_map_cells(lv.level, bl.x0, bl.y0, bl.x1 - bl.x0 + 1, bl.y1 - bl.y0 + 1) c)
SELECT ce.k_from, ce.k_to, kd.kind, kd.place_id, lv.level, ce.leg
  FROM ce CROSS JOIN lv JOIN kd ON kd.x = ce.cx AND kd.y = ce.cy
 ORDER BY ce.k_from;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_route(p_x0 integer, p_y0 integer, p_x1 integer, p_y1 integer, p_max integer DEFAULT NULL::integer, p_from integer DEFAULT 1)
 RETURNS TABLE(k_from integer, k_to integer, kind text, place_id uuid, level integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground under a straight walk (rpg_map_line): rpg_map_route_path with one leg, the one home of how a walk is read.
SELECT r.k_from, r.k_to, r.kind, r.place_id, r.level FROM public.rpg_map_route_path(ARRAY[p_x0, p_x1], ARRAY[p_y0, p_y1], p_max, p_from) r;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_path_at(p_xs integer[], p_ys integer[], p_k integer)
 RETURNS TABLE(x integer, y integer, leg integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
-- The square a walk along a path of straight legs (rpg_map_route_path) is on after p_k steps, and the leg it is on: step
-- 0 is the first point, the last step the last point; each leg walks as rpg_map_line_at does. A path of one leg is
-- rpg_map_line_at itself.
WITH lg AS (SELECT i, p_xs[i] AS x0, p_ys[i] AS y0, p_xs[i + 1] AS x1, p_ys[i + 1] AS y1, l.steps
              FROM generate_series(1, cardinality(p_xs) - 1) AS i
             CROSS JOIN LATERAL public.rpg_map_line(p_xs[i], p_ys[i], p_xs[i + 1], p_ys[i + 1]) l),
     cu AS (SELECT lg.*, sum(lg.steps) OVER (ORDER BY lg.i) - lg.steps AS c0 FROM lg)
SELECT s.x, s.y, cu.i
  FROM cu CROSS JOIN LATERAL public.rpg_map_line_at(cu.x0, cu.y0, cu.x1, cu.y1, least(greatest(p_k - cu.c0, 0), cu.steps)::integer) s
 WHERE p_k > cu.c0 OR cu.i = 1
 ORDER BY cu.i DESC LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_road_path(p_sx integer, p_sy integer, p_gx integer, p_gy integer)
 RETURNS TABLE(n integer, x integer, y integer, class integer, place uuid, stop boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The way a walk goes from p_sx, p_sy to p_gx, p_gy (world squares from 0; step 8b): straight across the land, or
-- along the roads where that is quicker. Off a road walking takes 5/3 as long as on one (Tobler 1993: off a path, 3/5
-- of the speed; map_road_keep), so the way is the one with the fewest steps when each step off a road counts 5/3:
-- straight to the end, or over to a road (to a place it joins, or the nearest point of a stretch of it), along the
-- roads (rpg_map_roads: highways, roads and lanes; and the place cards that are roads, like the Cursed Road) and off
-- again to the end. The roads looked at lie within map_road_plan town squares (7.2 miles) of the start, toward the
-- end; when the end lies farther, the way goes along the roads as far as they help and stops there (stop: the walk
-- ends its turn there and looks again next turn), unless no road helps, when it goes straight, or a stretch the end
-- lies by reaches in, when it goes along it all the way. A walk of one battle
-- grid (12 squares) or less goes straight: the battle grid has its roads as ground.
-- One row a point of the way, from the start (n = 0) to the last: class = how the leg that arrives there is walked
-- (1 to 3 along a road of that size, 4 along the place card place, nothing across the land).
DECLARE
  v_world bigint; v_lt double precision; v_keep double precision; v_reach double precision;
  v_dx bigint; v_tx double precision; v_ty double precision; v_dist double precision;
  v_ex double precision; v_ey double precision; v_far boolean; v_m double precision;
  v_bx0 bigint; v_by0 bigint; v_bx1 bigint; v_by1 bigint;
  l_k integer[]; l_ax double precision[]; l_ay double precision[]; l_bx double precision[]; l_by double precision[];
  l_a text[]; l_b text[]; l_p uuid[];
  v_id text[]; v_x double precision[]; v_y double precision[]; v_nv integer; v_s integer; v_t integer;
  e_a integer[]; e_b integer[]; e_c double precision[]; e_k integer[]; e_p uuid[]; v_off integer[];
  v_d double precision[]; v_prev integer[]; v_pe integer[]; v_done boolean[];
  u integer; i integer; j integer; v_best double precision; v_nd double precision;
  v_path integer[] := '{}'; v_cls integer[] := '{}'; v_pls uuid[] := '{}'; v_last integer;
BEGIN
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  SELECT s.value INTO v_lt FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_town_lattice';
  SELECT s.value INTO v_keep FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_keep';
  SELECT s.value * v_lt INTO v_reach FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_road_plan';
  -- the end counted the short way round the world from the start
  SELECT l.dx, l.steps INTO v_dx, v_dist FROM public.rpg_map_line(p_sx, p_sy, p_gx, p_gy) l;
  v_tx := p_sx + v_dx; v_ty := p_gy;
  IF v_dist > 12 THEN
    -- the roads looked at: round the stretch from the start toward the end, at most map_road_plan town squares long
    v_far := v_dist > v_reach;
    v_ex := CASE WHEN v_far THEN p_sx + (v_tx - p_sx) * v_reach / v_dist ELSE v_tx END;
    v_ey := CASE WHEN v_far THEN p_sy + (v_ty - p_sy) * v_reach / v_dist ELSE v_ty END;
    v_m := greatest(300, least(0.7 * least(v_dist, v_reach), v_reach / 2));
    v_bx0 := floor(least(p_sx, v_ex) - v_m); v_bx1 := ceil(greatest(p_sx, v_ex) + v_m);
    v_by0 := floor(least(p_sy, v_ey) - v_m); v_by1 := ceil(greatest(p_sy, v_ey) + v_m);
    -- every stretch of road there, and every place card that is a road (it runs from end to end)
    SELECT array_agg(q.k), array_agg(q.ax), array_agg(q.ay), array_agg(q.bx), array_agg(q.by), array_agg(q.a), array_agg(q.b), array_agg(q.p)
      INTO l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b, l_p
      FROM (SELECT r.class AS k, r.ax, r.ay, r.bx, r.by, r.a, r.b, NULL::uuid AS p
              FROM public.rpg_map_roads(7, v_bx0::integer, v_by0::integer, (v_bx1 - v_bx0)::integer, (v_by1 - v_by0)::integer, 7, NULL, 0) r
            UNION ALL
            SELECT 4, e.x0, e.y0, e.x1, e.y1, 'end-' || p.id || '-0', 'end-' || p.id || '-1', p.id
              FROM public.rpg_creatures p
             CROSS JOIN LATERAL (SELECT p.place_x + v_world * floor(((v_bx0 + v_bx1) / 2.0 - p.place_x) / v_world + 0.5) AS cx) m
             CROSS JOIN LATERAL (SELECT CASE WHEN p.place_w >= p.place_h THEN m.cx - p.place_w / 2.0 ELSE m.cx END AS x0,
                                        CASE WHEN p.place_w >= p.place_h THEN p.place_y::double precision ELSE p.place_y - p.place_h / 2.0 END AS y0,
                                        CASE WHEN p.place_w >= p.place_h THEN m.cx + p.place_w / 2.0 ELSE m.cx END AS x1,
                                        CASE WHEN p.place_w >= p.place_h THEN p.place_y::double precision ELSE p.place_y + p.place_h / 2.0 END AS y1) e
             WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL
               AND p.place_penalty IS NOT NULL AND p.place_icon = 'road'
               AND public.rpg_seg_box(e.x0, e.y0, e.x1, e.y1, v_bx0, v_by0, v_bx1, v_by1)) q;
  END IF;
  IF l_k IS NULL THEN
    -- nothing to look at: straight
    RETURN QUERY SELECT 0, p_sx, p_sy, NULL::integer, NULL::uuid, false UNION ALL SELECT 1, p_gx, p_gy, NULL::integer, NULL::uuid, false;
    RETURN;
  END IF;

  -- the places: every end of a stretch, the start, the end, and the nearest point of the nearest six stretches to the
  -- start and to the end (where a walk joins a road or leaves it between two places)
  WITH en AS (SELECT q.id, min(q.x) AS x, min(q.y) AS y
                FROM (SELECT u.a AS id, u.ax AS x, u.ay AS y FROM unnest(l_a, l_ax, l_ay) AS u(a, ax, ay)
                      UNION ALL SELECT u.b, u.bx, u.by FROM unnest(l_b, l_bx, l_by) AS u(b, bx, by)) q GROUP BY q.id),
       pj AS (SELECT w.who, w.n0, s.n AS seg,
                     s.ax + t.t * (s.bx - s.ax) AS px, s.ay + t.t * (s.by - s.ay) AS py,
                     greatest(abs(s.ax + t.t * (s.bx - s.ax) - w.wx), abs(s.ay + t.t * (s.by - s.ay) - w.wy)) AS gap
                FROM (VALUES ('S', 0, p_sx::double precision, p_sy::double precision), ('T', 1, v_tx, v_ty)) AS w(who, n0, wx, wy)
               CROSS JOIN LATERAL unnest(l_ax, l_ay, l_bx, l_by) WITH ORDINALITY AS s(ax, ay, bx, by, n)
               CROSS JOIN LATERAL (SELECT CASE WHEN power(s.bx - s.ax, 2) + power(s.by - s.ay, 2) = 0 THEN 0
                                               ELSE least(greatest(((w.wx - s.ax) * (s.bx - s.ax) + (w.wy - s.ay) * (s.by - s.ay))
                                                                   / (power(s.bx - s.ax, 2) + power(s.by - s.ay, 2)), 0), 1) END AS t) t
),
       pk AS (SELECT pj.*, row_number() OVER (PARTITION BY pj.who ORDER BY pj.gap, pj.seg) AS r FROM pj),
       al AS (SELECT en.id, en.x, en.y, 0 AS o FROM en
              UNION ALL SELECT 'S', p_sx, p_sy, 1
              UNION ALL SELECT 'T', v_tx, v_ty, 2
              UNION ALL SELECT 'p' || pk.who || '-' || pk.seg, pk.px, pk.py, 3 FROM pk WHERE pk.r <= 6)
  SELECT array_agg(al.id ORDER BY al.o, al.id), array_agg(al.x ORDER BY al.o, al.id), array_agg(al.y ORDER BY al.o, al.id)
    INTO v_id, v_x, v_y FROM al;
  v_nv := cardinality(v_id);
  v_s := array_position(v_id, 'S'); v_t := array_position(v_id, 'T');

  -- the ways between places, each its cost in steps (the larger of the two gaps: a diagonal step costs the same as a
  -- straight one), a step off the road counted 5/3 (1 / map_road_keep); both ways, grouped by the place they leave
  WITH ix AS (SELECT u.id, u.i::integer AS i FROM unnest(v_id) WITH ORDINALITY AS u(id, i)),
       sg AS (SELECT s.*, a.i AS ia, b.i AS ib FROM unnest(l_k, l_ax, l_ay, l_bx, l_by, l_a, l_b, l_p) WITH ORDINALITY AS s(k, ax, ay, bx, by, a, b, p, n)
                JOIN ix a ON a.id = s.a JOIN ix b ON b.id = s.b),
       ed AS (
         -- along a stretch of road; along a place card that is a road at its own ground
         SELECT sg.ia AS a, sg.ib AS b, greatest(abs(sg.bx - sg.ax), abs(sg.by - sg.ay)) * (1 + coalesce(g.penalty, 0) / 100.0) AS c, sg.k, sg.p
           FROM sg LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL
         UNION ALL
         -- the ends of a place card that is a road join the places within 400 squares of them
         SELECT a.i, b.i, greatest(abs(v_x[b.i] - v_x[a.i]), abs(v_y[b.i] - v_y[a.i])) / v_keep, NULL, NULL
           FROM ix a JOIN ix b ON a.id LIKE 'end-%' AND b.i <> a.i AND b.id NOT IN ('S', 'T') AND b.id NOT LIKE 'p%-%'
          WHERE greatest(abs(v_x[b.i] - v_x[a.i]), abs(v_y[b.i] - v_y[a.i])) <= 400
         UNION ALL
         -- the start straight to the end
         SELECT v_s, v_t, v_dist / v_keep, NULL, NULL
         UNION ALL
         -- the start over to its eight nearest places
         SELECT v_s, q.i, q.c / v_keep, NULL, NULL
           FROM (SELECT ix.i, greatest(abs(v_x[ix.i] - p_sx), abs(v_y[ix.i] - p_sy)) AS c FROM ix WHERE ix.id NOT IN ('S', 'T') AND ix.id NOT LIKE 'p%-%' ORDER BY 2, 1 LIMIT 8) q
         UNION ALL
         -- the eight nearest places over to the end; every place when the end lies past the roads looked at
         SELECT q.i, v_t, q.c / v_keep, NULL, NULL
           FROM (SELECT ix.i, greatest(abs(v_x[ix.i] - v_tx), abs(v_y[ix.i] - v_ty)) AS c FROM ix WHERE ix.id NOT IN ('S', 'T') AND ix.id NOT LIKE 'p%-%'
                  ORDER BY 2, 1 LIMIT CASE WHEN v_far THEN NULL ELSE 8 END) q
         UNION ALL
         -- the start or the end over to the nearest point of a stretch, then along the stretch to either end of it
         SELECT CASE WHEN split_part(ix.id, '-', 1) = 'pS' THEN v_s ELSE v_t END, ix.i,
                greatest(abs(v_x[ix.i] - CASE WHEN split_part(ix.id, '-', 1) = 'pS' THEN p_sx ELSE v_tx END),
                         abs(v_y[ix.i] - CASE WHEN split_part(ix.id, '-', 1) = 'pS' THEN p_sy ELSE v_ty END)) / v_keep, NULL, NULL
           FROM ix WHERE ix.id LIKE 'p%-%'
         UNION ALL
         SELECT ix.i, e.i, greatest(abs(v_x[e.i] - v_x[ix.i]), abs(v_y[e.i] - v_y[ix.i])) * (1 + coalesce(g.penalty, 0) / 100.0), sg.k, sg.p
           FROM ix JOIN sg ON sg.n = split_part(ix.id, '-', 2)::bigint
          CROSS JOIN LATERAL (VALUES (sg.ia), (sg.ib)) AS e(i)
           LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL
          WHERE ix.id LIKE 'p%-%'
         UNION ALL
         -- the start and the end on the same stretch: along it from one to the other
         SELECT a.i, b.i, greatest(abs(v_x[b.i] - v_x[a.i]), abs(v_y[b.i] - v_y[a.i])) * (1 + coalesce(g.penalty, 0) / 100.0), sg.k, sg.p
           FROM ix a JOIN ix b ON a.id LIKE 'pS-%' AND b.id = 'pT-' || split_part(a.id, '-', 2)
           JOIN sg ON sg.n = split_part(a.id, '-', 2)::bigint
           LEFT JOIN LATERAL public.rpg_map_ground('place', sg.p) g ON sg.p IS NOT NULL),
       bw AS (SELECT ed.a, ed.b, ed.c, ed.k, ed.p FROM ed UNION ALL SELECT ed.b, ed.a, ed.c, ed.k, ed.p FROM ed),
       nb AS (SELECT bw.*, row_number() OVER (ORDER BY bw.a, bw.b, bw.c)::integer AS j FROM bw)
  SELECT array_agg(nb.a ORDER BY nb.j), array_agg(nb.b ORDER BY nb.j), array_agg(nb.c ORDER BY nb.j), array_agg(nb.k ORDER BY nb.j), array_agg(nb.p ORDER BY nb.j),
         (SELECT array_agg(coalesce((SELECT min(q.j) FROM nb q WHERE q.a >= g), (SELECT count(*) FROM nb) + 1)::integer ORDER BY g)
            FROM generate_series(1, v_nv + 1) AS g)
    INTO e_a, e_b, e_c, e_k, e_p, v_off
    FROM nb;

  -- the cheapest way from the start to the end (Dijkstra 1959)
  v_d := array_fill(1e18::double precision, ARRAY[v_nv]); v_prev := array_fill(0, ARRAY[v_nv]); v_pe := array_fill(0, ARRAY[v_nv]);
  v_done := array_fill(false, ARRAY[v_nv]);
  v_d[v_s] := 0;
  LOOP
    u := 0; v_best := 1e18;
    FOR i IN 1 .. v_nv LOOP
      IF NOT v_done[i] AND v_d[i] < v_best THEN v_best := v_d[i]; u := i; END IF;
    END LOOP;
    EXIT WHEN u = 0 OR u = v_t;
    v_done[u] := true;
    FOR j IN v_off[u] .. v_off[u + 1] - 1 LOOP
      v_nd := v_best + e_c[j];
      IF v_nd < v_d[e_b[j]] THEN v_d[e_b[j]] := v_nd; v_prev[e_b[j]] := u; v_pe[e_b[j]] := j; END IF;
    END LOOP;
  END LOOP;

  -- the way back from the end
  u := v_t;
  WHILE u <> 0 AND u <> v_s LOOP
    v_path := u || v_path; v_cls := e_k[v_pe[u]] || v_cls; v_pls := e_p[v_pe[u]] || v_pls;
    u := v_prev[u];
  END LOOP;
  -- no road on the way: straight
  IF u = 0 OR NOT EXISTS (SELECT 1 FROM unnest(v_cls) AS k(k) WHERE k.k IS NOT NULL) THEN
    RETURN QUERY SELECT 0, p_sx, p_sy, NULL::integer, NULL::uuid, false UNION ALL SELECT 1, p_gx, p_gy, NULL::integer, NULL::uuid, false;
    RETURN;
  END IF;
  -- when the end lies past the roads looked at and the way leaves the roads for it from a place (not from a point of a
  -- stretch the end lies by), the way stops where it leaves the last road
  v_last := cardinality(v_path);
  IF v_far AND v_last > 1 AND v_id[v_path[v_last - 1]] NOT LIKE 'pT-%' THEN
    WHILE v_last > 0 AND v_cls[v_last] IS NULL LOOP v_last := v_last - 1; END LOOP;
  ELSE
    v_far := false;
  END IF;
  RETURN QUERY
  WITH pt AS (SELECT 0 AS i, p_sx::bigint AS x, p_sy::bigint AS y, NULL::integer AS k, NULL::uuid AS p
              UNION ALL
              SELECT q.i, CASE WHEN v_path[q.i] = v_t THEN p_sx + v_dx ELSE round(v_x[v_path[q.i]])::bigint END,
                     CASE WHEN v_path[q.i] = v_t THEN p_gy::bigint ELSE round(v_y[v_path[q.i]])::bigint END, v_cls[q.i], v_pls[q.i]
                FROM generate_series(1, v_last) AS q(i)),
       -- two points of the way on one square are one
       dd AS (SELECT pt.*, lag(pt.x) OVER (ORDER BY pt.i) AS px, lag(pt.y) OVER (ORDER BY pt.i) AS py FROM pt),
       kp AS (SELECT dd.* FROM dd WHERE dd.i = 0 OR NOT (dd.x = dd.px AND dd.y = dd.py))
  SELECT (row_number() OVER (ORDER BY kp.i) - 1)::integer, mod(kp.x + v_world, v_world)::integer, kp.y::integer, kp.k, kp.p,
         v_far AND kp.i = max(kp.i) OVER ()
    FROM kp ORDER BY kp.i;
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
-- The walk runs straight (rpg_map_line), or along the roads where that is quicker (step 8b, rpg_map_road_path: off a
-- road walking takes 5/3 as long, Tobler 1993): leg by leg from place to place, the ground from rpg_map_route_path,
-- looked at closer where the sea starts. A leg along a road is walked on the road: road ground (rpg_map_band road,
-- +0% to +10%), a mountain road over mountains (pass), the ground of the road card itself along a place card that is a road,
-- the streets in a village, town or city and the ground of an open place it crosses; snow and ice stay snow and ice;
-- where a road meets a river or a lake it crosses it (a bridge, a ford or a ferry), walked as the road; the sea stops
-- it. It stops:
--   at the shore: nobody walks into the sea (2A), nor into water too rough to swim, nor ends a walk in water too deep
--   to wade; the piece stands on the last dry square before it;
--   water too deep to wade is swum (step 7b): each square takes map_swim_pct (170) more time, and every round_ticks (20)
--   in the water the site rolls the swimmer's Swimming (Swimming with Gear with swimming gear on) against the water's
--   pull there (rpg_map_swim_difficulty). A miss puts them under: a round lost, and they roll again; under longer than
--   swim_breath_ticks (180) without breathing water, every tick costs vitality at a full bar per swim_drown_ticks (540).
--   Once in the water they swim on until out of it, past the end of the walking day if need be; if they go down
--   (0 vitality) the walk stops there, in the water. The rolls train the skill like any roll (all their points at once);
--   a mountain cliff is climbed (step 7c): on the battle grid each cliff square (rpg_map_steep, rpg_map_cliff_angle)
--   takes its climb's time (rpg_map_climb) and a Climbing roll (Climbing with Gear with climbing gear on) against its
--   difficulty (a walk read in coarser runs, longer than 72 squares, picks its way round cliffs: the mountain's own time
--   allows for that). A miss is a fall the height of the square ((height / climb_fall_down_m, 15 m) squared of their vitality) and the climb again; if
--   they go down the walk stops at the foot of that cliff. Climbing trains like swimming;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   at the end of the roads it looked at, when the square it is heading for lies farther (rpg_map_road_path stop): the
--   square it was heading for is kept, as when the day runs out, and the next turn looks again from there;
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
  v_cliff double precision; v_cl_rise double precision; v_cl_dif numeric; v_cl_key text; v_cl_skill numeric; v_cl_gear boolean;
  v_cl_rolls integer := 0; v_cl_points numeric := 0; v_cl_falls integer := 0; v_cl_harm integer := 0; v_cl_count integer := 0; v_cl_maxdif numeric := 0;
  v_cl_n integer; v_cl_extra numeric; v_cl_try bigint; v_cl_left integer; v_cl_max integer; v_fixed bigint := 0; j integer;
  v_wx integer[]; v_wy integer[]; v_wk integer[]; v_wp uuid[]; v_stop boolean; v_cum integer[]; v_lk integer; v_kind text; v_place uuid;
  v_onroad integer := 0; v_ex integer; v_ey integer;
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
  -- the way: straight, or along the roads (rpg_map_road_path): its points, how each leg is walked (v_wk[i + 1] for the
  -- leg from point i to point i + 1), and the steps walked before each point
  SELECT array_agg(r.x ORDER BY r.n), array_agg(r.y ORDER BY r.n), array_agg(r.class ORDER BY r.n), array_agg(r.place ORDER BY r.n), coalesce(bool_or(r.stop), false)
    INTO v_wx, v_wy, v_wk, v_wp, v_stop
    FROM public.rpg_map_road_path(v_sx, v_sy, v_gx, v_gy) r;
  SELECT array_agg(q.c ORDER BY q.i) INTO v_cum
    FROM (SELECT g.i, coalesce(sum(l.steps) OVER (ORDER BY g.i), 0)::integer AS c
            FROM generate_series(1, cardinality(v_wx)) AS g(i)
            LEFT JOIN LATERAL public.rpg_map_line(v_wx[g.i - 1], v_wy[g.i - 1], v_wx[g.i], v_wy[g.i]) l ON g.i > 1) q;
  v_steps := v_cum[cardinality(v_cum)];
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
    FOR v_r IN SELECT * FROM public.rpg_map_route_path(v_wx, v_wy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_path_at(v_wx, v_wy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0; v_wc := 0; v_swim := false;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- on a leg along a road, the road (step 8b): road ground, also over a river or a lake (its crossing); a mountain
      -- road over mountains; the ground of a road card; the streets of a village, town or city, an open place, snow and
      -- ice and the sea stay what they are
      v_lk := v_wk[v_r.leg + 1]; v_kind := v_r.kind; v_place := v_r.place_id;
      IF v_lk = 4 AND v_kind <> 'sea' THEN v_kind := 'place'; v_place := v_wp[v_r.leg + 1];
      ELSIF v_lk IS NOT NULL AND v_kind = 'mountains' THEN v_kind := 'pass';
      ELSIF v_lk IS NOT NULL AND v_kind NOT IN ('sea', 'ice', 'town', 'place', 'pass') THEN v_kind := 'road';
      END IF;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_kind IN ('water', 'deep') OR (v_r.level < 7 AND v_lk IS NULL) THEN
        SELECT w.depth, w.line, w.current INTO v_wd, v_wl, v_wc
          FROM public.rpg_map_flow(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF v_kind = 'deep' AND v_r.level = 7 THEN
        -- water too deep to wade, on the battle grid: swum (step 7b), unless it pulls too hard to swim or the walk
        -- would end in it (then it stops at the water's edge)
        v_dif := public.rpg_map_swim_difficulty(v_wc);
        IF v_dif IS NOT NULL AND v_r.k_to < v_steps THEN v_pen := public.rpg_map_wade_pct(v_wd); v_swim := true; END IF;
      -- a road crosses rivers: only off the road is a deep river looked at closer
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep) AND v_lk IS NULL) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_kind, v_place) b;
      END IF;
      -- a cliff on the battle grid: climbed, at its climb's time
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_kind = 'mountains' AND v_r.level = 7 THEN
        SELECT public.rpg_map_cliff_angle(t.steep) INTO v_cliff FROM public.rpg_map_steep(7, v_hx - 1, v_hy - 1, 1, 1) t;
        IF v_cliff IS NOT NULL THEN SELECT m.pct, m.rise, m.difficulty INTO v_pen, v_cl_rise, v_cl_dif FROM public.rpg_map_climb(v_cliff) m; END IF;
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
      -- a cliff on this battle-grid square: climbed
      IF v_n > 0 AND v_cliff IS NOT NULL THEN
        v_cl_n := v_n;
        IF v_cl_n > 0 AND v_cl_key IS NULL THEN
          v_cl_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
                       AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
          v_cl_key := CASE WHEN v_cl_gear THEN 'climb_gear' ELSE 'CL' END;
          v_cl_skill := public.rpg_participant_value(p_participant_id, v_cl_key);
          v_cl_left := (public.rpg_participant_vitality(p_participant_id)->>'left')::integer - v_sw_harm;
          v_cl_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
        END IF;
        v_cl_extra := 0;
        FOR j IN 1 .. coalesce(v_cl_n, 0) LOOP
          v_cl_try := v_b;
          v_cl_count := v_cl_count + 1; v_cl_maxdif := greatest(v_cl_maxdif, v_cl_dif);
          LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_need2 := (public.rpg_needed(coalesce(v_cl_skill, 0), v_cl_dif)->>'needed')::numeric;
            v_cl_rolls := v_cl_rolls + 1;
            v_cl_points := v_cl_points + v_d100 * v_need2 / 100;
            EXIT WHEN v_d100 >= v_need2;
            -- a slip: a fall the height of the square, and the climb again
            v_cl_falls := v_cl_falls + 1;
            v_cl_harm := v_cl_harm + greatest(ceil(v_cl_max * power(v_cl_rise / public.rpg_setting('climb_fall_down_m')::double precision, 2))::integer, 1);
            IF v_cl_harm >= v_cl_left THEN v_why := 'fell'; EXIT; END IF;
            v_cl_extra := v_cl_extra + v_cl_try;
          END LOOP;
          EXIT WHEN v_why = 'fell';
        END LOOP;
        IF v_why = 'fell' THEN
          -- down at the foot of that cliff: the time spent there counts, the squares past it are not walked
          v_fixed := v_fixed + ceil(v_cl_extra)::bigint;
          v_n := 0;
        ELSIF v_n > 0 THEN
          v_b := v_b + ceil(v_cl_extra / v_n)::integer;
        END IF;
      END IF;
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A); none in the water
      IF v_n > 0 AND NOT v_swim AND v_why IS DISTINCT FROM 'fell' THEN
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
      EXIT WHEN v_why IN ('meet', 'drown', 'fell');
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
  -- at the end of the roads it looked at, short of where it is heading
  IF v_why IS NULL AND v_stop THEN v_why := 'way'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back; someone
  -- who went down in the water stays where they went down
  IF v_why = 'drown' THEN v_k := v_reach; END IF;
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_path_at(v_wx, v_wy, g.k) s),
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
  v_walk := public.rpg_ticks_at(v_speed, (v_base + v_fixed) / 100.0);
  v_arrived := v_k = v_steps AND NOT v_stop;
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') NOT IN ('drown', 'fell') AND v_p.day_walk_ticks + v_walk >= v_day);
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_path_at(v_wx, v_wy, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_y END,
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
  -- the climbs: what the falls cost, and the points every roll paid, all at once
  IF v_cl_rolls > 0 THEN
    IF v_cl_harm > 0 THEN
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_cl_harm);
    END IF;
    IF v_cl_skill IS NOT NULL AND v_cl_points > 0 THEN
      v_sw_val := (public.rpg_sheet_values(v_p.character_id)->'values'->>v_cl_key)::numeric;
      PERFORM public.rpg_add_skill_points(v_p.character_id, v_cl_key, v_cl_points, v_sw_val);
      PERFORM public.rpg_trickle(v_p.character_id, v_cl_key, v_cl_points, '[]'::jsonb);
    END IF;
  END IF;
  -- what the character saw on the way (rpg_map_found reads these stretches)
  -- a stretch a leg of the way, as far as it was walked; and how many of those legs were on a road
  FOR i IN 1 .. cardinality(v_wx) - 1 LOOP
    EXIT WHEN v_cum[i] >= v_k;
    IF v_cum[i + 1] <= v_k THEN v_ex := v_wx[i + 1]; v_ey := v_wy[i + 1]; ELSE v_ex := v_tx; v_ey := v_ty; END IF;
    PERFORM public.rpg_map_trail_add(v_p.character_id, v_wx[i] + 1, v_wy[i] + 1, v_ex + 1, v_ey + 1);
    IF v_wk[i + 1] IS NOT NULL THEN v_onroad := v_onroad + 1; END IF;
  END LOOP;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk)
                                   || CASE WHEN v_onroad > 0 THEN ' along the road' || CASE WHEN v_onroad > 1 THEN 's' ELSE '' END ELSE '' END || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'way' THEN ' The roads go on: the walk carries on from here next turn.' ELSE '' END
         || CASE WHEN v_why = 'shore' THEN ' The sea, water too rough to swim, or the water''s edge stops the walk.' ELSE '' END
         || CASE WHEN v_sw_rolls > 0 THEN ' Swims deep water: ' || v_sw_rolls || ' Swimming rolls' || CASE WHEN v_sw_gear THEN ' with gear' ELSE '' END
                                          || ' (' || trim_scale(coalesce(v_sw_skill, 0)) || ' against up to ' || trim_scale(v_sw_maxdif) || ')'
                                          || CASE WHEN v_sw_dips > 0 THEN ', under water ' || v_sw_dips || CASE WHEN v_sw_dips = 1 THEN ' time' ELSE ' times' END
                                                  || ', the longest ' || public.rpg_map_duration_text(v_sw_long) ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_sw_harmt > 0 THEN ' Out of breath under water: ' || ceil(v_sw_max * v_sw_harmt::numeric / v_drown) || ' damage.' ELSE '' END
         || CASE WHEN v_why = 'drown' THEN ' Goes down in the water.' ELSE '' END
         || CASE WHEN v_cl_count > 0 THEN ' Climbs ' || v_cl_count || CASE WHEN v_cl_count = 1 THEN ' cliff: ' ELSE ' cliffs: ' END || v_cl_rolls || CASE WHEN v_cl_rolls = 1 THEN ' Climbing roll' ELSE ' Climbing rolls' END
                                          || CASE WHEN v_cl_gear THEN ' with gear' ELSE '' END || ' (' || trim_scale(coalesce(v_cl_skill, 0)) || ' against up to ' || trim_scale(v_cl_maxdif) || ')'
                                          || CASE WHEN v_cl_falls > 0 THEN ', ' || v_cl_falls || CASE WHEN v_cl_falls = 1 THEN ' fall' ELSE ' falls' END || ': ' || v_cl_harm || ' damage' ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_why = 'fell' THEN ' Falls and is down at the foot of a cliff.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text((SELECT l.steps FROM public.rpg_map_line(v_tx, v_ty, v_gx, v_gy) l)) || ' to go.' ELSE '' END;
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
-- towns = the villages, towns and cities the read shows (step 8; rpg_map_towns): the Country grid its cities and the
-- Region grid all three, each a mark in the cell its middle stands in (its id among the marks of that cell); on the City
-- grid and finer the cells of the ground of each (rpg_map_town_cells), which come as kind place with place = its id,
-- so they are drawn and named like a place with ground. A grid drawn fine carries them in its detail the same way.
-- Each is told as rpg_map_town_entry tells it; the Region grid lists its towns and cities.
-- roads = the roads the read draws (step 8b; rpg_map_roads): highways from the Country grid down, roads and lanes from
-- the Region grid down to the District grid (a place shown whole draws those of the grid of its detail; the battle grid has
-- them as ground of its own, road and mountain road, among its cells). Each piece of road is [size (1 highway, 2 road,
-- 3 lane), x0, y0, x1, y1] in thousandths of a cell from the top-left corner: a stretch cut to the cells it crosses
-- that are found and not sea (a road crosses rivers and lakes, by a bridge, a ford or a ferry). road_width = how wide
-- each size is, in thousandths of a cell of what is drawn.
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
       -- the kinds of the cells of a Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (3, 4)),
       -- the villages, towns and cities marked on this grid (the Country grid its cities, the Region grid all three),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT kj.k FROM kj)) t
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
                   WHERE cl.seen AND cl.town IS NOT NULL) q),
         -- what grows at the sites of this grid, for its roads
         (SELECT jsonb_object_agg(tw.id, tw.kind) FROM tw),
         -- where a road is drawn (step 8b): found, and not the sea
         (SELECT jsonb_object_agg(cl.x || ',' || cl.y, 1) FROM cl WHERE cl.seen AND cl.kind <> 'sea')
    INTO v_cells, v_towns, v_kinds, v_shown;

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
                     WHERE d.seen AND d.town IS NOT NULL) q),
           (SELECT jsonb_object_agg(dt.id, dt.kind) FROM dt),
           (SELECT jsonb_object_agg(d.x || ',' || d.y, 1) FROM d WHERE d.seen AND d.kind <> 'sea')
      INTO v_detail, v_dtowns, v_dkinds, v_dshown
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
                      coalesce(CASE WHEN v_detail IS NULL THEN v_shown ELSE v_dshown END, '{}'::jsonb) AS shown),
         lg AS (SELECT row_number() OVER () AS n, r.*
                  FROM public.rpg_map_roads(CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_l.level ELSE v_l.level + 1 END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_x0 ELSE v_x0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_y0 ELSE v_y0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_cols ELSE v_dc END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_rows ELSE v_dr END,
                                            v_what, CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_kinds ELSE v_dkinds END, 0) r),
         -- each stretch in cells of what is drawn, from its first cell
         lc AS (SELECT lg.n, lg.class, lg.ax / g.cell - g.x0 AS u0, lg.ay / g.cell - g.y0 AS v0, lg.bx / g.cell - g.x0 AS u1, lg.by / g.cell - g.y0 AS v1,
                       g.x0, g.y0, g.cols, g.rows, g.shown
                  FROM lg CROSS JOIN g),
         -- the part of the stretch inside each cell it crosses (t0 to t1: 0 at its start, 1 at its end), where a road of
         -- its size is drawn
         ct AS (SELECT lc.n, lc.class, lc.u0, lc.v0, lc.u1, lc.v1, greatest(0, tx.lo, ty.lo) AS t0, least(1, tx.hi, ty.hi) AS t1
                  FROM lc
                 CROSS JOIN LATERAL generate_series(greatest(floor(least(lc.u0, lc.u1))::integer, 0), least(floor(greatest(lc.u0, lc.u1))::integer, lc.cols - 1)) AS i
                 CROSS JOIN LATERAL generate_series(greatest(floor(least(lc.v0, lc.v1))::integer, 0), least(floor(greatest(lc.v0, lc.v1))::integer, lc.rows - 1)) AS j
                 CROSS JOIN LATERAL (SELECT CASE WHEN lc.u1 = lc.u0 THEN 0 ELSE least((i - lc.u0) / (lc.u1 - lc.u0), (i + 1 - lc.u0) / (lc.u1 - lc.u0)) END AS lo,
                                            CASE WHEN lc.u1 = lc.u0 THEN 1 ELSE greatest((i - lc.u0) / (lc.u1 - lc.u0), (i + 1 - lc.u0) / (lc.u1 - lc.u0)) END AS hi) tx
                 CROSS JOIN LATERAL (SELECT CASE WHEN lc.v1 = lc.v0 THEN 0 ELSE least((j - lc.v0) / (lc.v1 - lc.v0), (j + 1 - lc.v0) / (lc.v1 - lc.v0)) END AS lo,
                                            CASE WHEN lc.v1 = lc.v0 THEN 1 ELSE greatest((j - lc.v0) / (lc.v1 - lc.v0), (j + 1 - lc.v0) / (lc.v1 - lc.v0)) END AS hi) ty
                 WHERE greatest(0, tx.lo, ty.lo) < least(1, tx.hi, ty.hi)
                   AND lc.shown ? ((i + lc.x0) || ',' || (j + lc.y0))),
         -- the parts that follow on from one another make one piece
         pt AS (SELECT ct.*, CASE WHEN ct.t0 > coalesce(max(ct.t1) OVER (PARTITION BY ct.n ORDER BY ct.t0 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), -1) + 1e-9
                                  THEN 1 ELSE 0 END AS gap
                  FROM ct),
         pc AS (SELECT pt.*, sum(pt.gap) OVER (PARTITION BY pt.n ORDER BY pt.t0) AS run FROM pt)
    SELECT jsonb_agg(jsonb_build_array(q.class, round(q.x0 * 1000)::integer, round(q.y0 * 1000)::integer, round(q.x1 * 1000)::integer, round(q.y1 * 1000)::integer)
                     ORDER BY q.class DESC, q.n, q.run)
      INTO v_roads
      FROM (SELECT pc.n, pc.run, min(pc.class) AS class,
                   (min(pc.u0) + min(pc.t0) * (min(pc.u1) - min(pc.u0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS x0,
                   (min(pc.v0) + min(pc.t0) * (min(pc.v1) - min(pc.v0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS y0,
                   (min(pc.u0) + max(pc.t1) * (min(pc.u1) - min(pc.u0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS x1,
                   (min(pc.v0) + max(pc.t1) * (min(pc.v1) - min(pc.v0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS y1
              FROM pc GROUP BY pc.n, pc.run) q;
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
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$

;

UPDATE public.rpg_rules SET body = replace(body,
'On its turn a piece walks straight toward any square the game master picks, the whole way in one go.',
'On its turn a piece walks toward any square the game master picks, the whole way in one go: straight, or along the roads (see below).'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('straight, or along the roads' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'a city of 12,000 about two thirds of a mile.*',
'a city of 12,000 about two thirds of a mile.*

Roads join the places people live, straight from one to the next. A highway 6.5 m wide (about 6 squares, the width of the main Roman roads) runs from each city to the cities around it, by way of the market towns between; a road 4.9 m wide (about 4 squares, room for two carts to pass) joins each town to the towns around it; and a lane 2.4 m wide (about 2 squares, one cart) runs from each village toward its market town, as far as the next place where people live. Roads cross rivers and lakes on a bridge, a ford or a ferry, but never the sea, and keep out of any place with rough ground of its own, like the Old Forest; through an open place they run on its own ground. A square of road adds +0% to +10% time whatever ground it crosses, except a mountain road, which keeps three fifths of the time of mountains, +80% to +260%; snow and ice stay snow and ice. The Country grid shows the highways, the closer grids all three.
*At Speed 10 a mile of road takes 21 minutes, like open land, and a mile of mountain road 54 minutes instead of 1 hour 30.*

A walk keeps to the roads where they are quicker by its count: every step off a road counts as 5/3 of a step on one (walking off a path takes that much longer, Tobler 1993), and the walk takes the way with the fewest. It plans its way up to about 14 miles ahead; when the end lies farther and the roads lead on, it stops where its plan ends and can carry on from there next turn.
*A town 8 miles away across forest is 6 hours straight at Speed 10; by a road 10 miles long, 3 hours 30.*'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('Roads join the places people live' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'with a Swimming roll at the start of every turn in it (see Swimming). Where a square sits',
'with a Swimming roll at the start of every turn in it (see Swimming). Roads are 2 to 6 squares wide, and a square of road is +0% to +10% whatever it crosses, rivers and lakes too (a bridge, a ford or a ferry), except over mountains, +80% to +260%, and over snow and ice, which stay as they are. Where a square sits'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('a square of road is' IN body) = 0;

