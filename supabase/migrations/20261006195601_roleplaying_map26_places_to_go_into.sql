-- roleplaying map step 12c: places to go into (Peter 2026-10-06: caves, shrines, mines, camps, huts, rolled like
-- towns, never stored). New rpg_map_location_kinds, rpg_map_site_what and rpg_map_site_make (the sums of a landmark,
-- now for either class); rpg_map_landmark_what (a wrapper, read by nothing), rpg_map_landmark_rolls (12 rolls),
-- rpg_map_landmark_make (a landmark, else a place to go into), rpg_map_landmark_sites, rpg_map_landmarks,
-- rpg_map_landmark_squares (their shapes), rpg_map_landmark_cells, rpg_map_building_cells, rpg_map_climb_words,
-- rpg_map_icons, rpg_map_landmark_entry, rpg_map_view_block (feature); three settings; rule card world_map. No drops,
-- no table changes.

-- step 12c: places to go into (Peter 2026-10-06: caves, shrines, mines, camps, huts, rolled like towns, never stored)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label
  FROM (VALUES ('map_location_share_4', 0.25::numeric, 'Places to go into: share of Region-grid sites without a landmark where one stands (a great cave, mine workings, a war camp), on the best ground for it'),
               ('map_location_share_5', 0.3, 'Places to go into: share of City-grid sites without a landmark where one stands (a cave, a mine, a shrine, a camp, a hut), on the best ground for it'),
               ('map_location_share_6', 0.25, 'Places to go into: share of District-grid sites without a landmark where one stands (a hollow, a wayside shrine, a campsite, a hut), on the best ground for it')) AS v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = v.key);

CREATE OR REPLACE FUNCTION public.rpg_map_location_kinds()
 RETURNS TABLE(rank integer, kind text, icon text, words text, weight double precision, h_low double precision, h_high double precision, w_low double precision, w_high double precision, pattern text, ends text[], grounds jsonb)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The places to go into of the world map (step 12c; Peter 2026-10-06: smaller places to go into, caves, shrines, mines,
-- camps, huts, rolled like towns and never stored), the one home of what each can be, read as rpg_map_landmark_kinds is
-- (the same columns, the same meaning): rank = the coarsest grid that shows it (4 the Region grid to 6 the District
-- grid); weight = its share of the places of its rank (they add up to 1); h_low, h_high = how tall it stands in metres
-- (a cave or a mine: the rock over its mouth; a camp: its tents, or the palisade of a war camp); w_low, w_high = how far
-- across; pattern and ends = its name. Worked out when asked, never stored.
-- The sizes are of real ones: a great cave mouth in a cliff 15 to 40 m high (the Peak Cavern entrance, Derbyshire, is
-- 30 m wide and 18 m high); a cave a hillside knoll 6 to 20 m high; a mine's workings 60 to 200 m across of spoil heaps
-- round its adit, a lone mine 15 to 40 m; a Roman marching camp 2 to 4 m palisade round 80 to 200 m of tents for a
-- cohort or two; a shrine or chapel of ease 5 to 10 m across; a wayside cross 2 to 3.5 m; a hut or a shieling 4 to
-- 9 m across (a Highland bothy 5 by 4 m); a camp of a band 20 to 50 m across, a campsite 8 to 15 m.
-- Caves and mines on mountains and hills, a cave of the City grid in a wood too; shrines and huts on any dry ground;
-- camps in woods and on open land. Nothing in the sea, water, snow and ice, a road, or inside a place with ground of its own.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (4, 'cave',   'cave',   'Great cave',      0.4,    15,   40,    40,   120, '{A} {B}', ARRAY['Cavern', 'Caves', 'Deeps'],     '{"mountains": 1, "hills": 0.8}'),
    (4, 'mine',   'mine',   'Mine workings',   0.3,     6,   15,    60,   200, '{A} {B}', ARRAY['Mine', 'Delving', 'Workings'],  '{"mountains": 1, "hills": 0.8, "tundra": 0.2}'),
    (4, 'camp',   'camp',   'War camp',        0.3,     3,    5,    80,   200, '{A} {B}', ARRAY['Camp', 'Stockade'],             '{"plains": 1, "land": 0.8, "hills": 0.6, "forest": 0.6, "pine": 0.5, "desert": 0.4, "tundra": 0.3, "jungle": 0.3}'),
    (5, 'cave',   'cave',   'Cave',            0.3,     6,   20,    15,    40, '{A} {B}', ARRAY['Cave', 'Hole', 'Grotto'],       '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3, "jungle": 0.3}'),
    (5, 'mine',   'mine',   'Mine',            0.15,    3,    8,    15,    40, '{A} {B}', ARRAY['Mine', 'Adit', 'Delving'],      '{"mountains": 1, "hills": 0.8}'),
    (5, 'shrine', 'shrine', 'Shrine',          0.2,     4,    8,     5,    10, '{A} {B}', ARRAY['Shrine', 'Sanctum'],            '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3}'),
    (5, 'camp',   'camp',   'Camp',            0.15,    2,    3,    20,    50, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3}'),
    (5, 'hut',    'hut',    'Hut',             0.2,     3,    5,     5,     9, '{A} {B}', ARRAY['Hut', 'Lodge', 'Bothy'],        '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3}'),
    (6, 'cave',   'cave',   'Hollow',          0.3,     3,    8,     6,    15, '{A} {B}', ARRAY['Hollow', 'Hole'],               '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3}'),
    (6, 'shrine', 'shrine', 'Wayside shrine',  0.25,    2,  3.5,     1,   2.5, '{A} {B}', ARRAY['Cross', 'Shrine'],              '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3}'),
    (6, 'camp',   'camp',   'Campsite',        0.2,   1.5,  2.5,     8,    15, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3}'),
    (6, 'hut',    'hut',    'Hut',             0.25,    3,  4.5,     4,     7, '{A} {B}', ARRAY['Hut', 'Bothy'],                 '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_site_what(p_class text, p_rank integer, p_rolls integer[])
 RETURNS TABLE(kind text, icon text, words text, pattern text, ends text[], grounds jsonb, height double precision, across double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What six rolls make a site hold, whatever ground it stands on (step 12c; the one home of it, moved from
-- rpg_map_landmark_what): p_class 'landmark' reads rpg_map_landmark_kinds, 'location' (a place to go into)
-- rpg_map_location_kinds. The first roll picks the kind by its share of the rank (weight); the third and fourth how tall
-- and how wide, steady from the least to the most of its kind, as many small as big on a doubling scale. Nothing when
-- the class has no kind of that rank. Whether it stands at all is rpg_map_site_make, by the ground.
SELECT q.kind, q.icon, q.words, q.pattern, q.ends, q.grounds,
       q.h_low * power(q.h_high / q.h_low, (p_rolls[3] - 0.5) / 100),
       q.w_low * power(q.w_high / q.w_low, (p_rolls[4] - 0.5) / 100)
  FROM (SELECT k.*, sum(k.weight) OVER (ORDER BY k.kind, k.icon) AS cum
          FROM (SELECT * FROM public.rpg_map_landmark_kinds() WHERE p_class = 'landmark'
                UNION ALL
                SELECT * FROM public.rpg_map_location_kinds() WHERE p_class = 'location') k
         WHERE k.rank = p_rank) q
 WHERE (p_rolls[1] - 0.5) / 100 < q.cum
 ORDER BY q.cum LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_what(p_rank integer, p_rolls integer[])
 RETURNS TABLE(kind text, icon text, words text, pattern text, ends text[], grounds jsonb, height double precision, across double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What the rolls of a landmark site make it (step 12b2). Since step 12c it is rpg_map_site_what for a landmark, the one
-- home of it; nothing reads this any more.
SELECT * FROM public.rpg_map_site_what('landmark', p_rank, p_rolls[1:6]);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_rolls(p_w6 bigint, p_y6 bigint, p_seed integer)
 RETURNS integer[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The fixed-seed d100s of a landmark site (step 12b; rpg_map_roll part 16 at its rank-6 square, its column counted
-- round the world): 1 to 6 for a landmark (layers 1621 to 1626): which kind it is, whether it stands, how tall, how
-- wide, and the ending of its name (2); 7 to 12 the same for a place to go into (step 12c; layers 1641 to 1646), read
-- only where no landmark stands. The one home of them; what they mean is rpg_map_site_make.
SELECT ARRAY(SELECT public.rpg_map_roll(p_seed, CASE WHEN n <= 6 THEN 1620 + n ELSE 1634 + n END, p_w6::integer, p_y6::integer)
               FROM generate_series(1, 12) AS n ORDER BY n);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_site_make(p_class text, p_rank integer, p_x bigint, p_y bigint, p_rolls integer[], p_ground text)
 RETURNS TABLE(kind text, icon text, words text, name text, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a landmark (p_class 'landmark') or a place to go into ('location') stands at a site (rpg_map_landmark_sites),
-- the one home of it (step 12b as rpg_map_landmark_make; step 12c gave it the class): of its rank or nothing, what kind,
-- how tall and how wide, and its name, from its six rolls. Worked out when asked, never stored.
-- The first roll picks the kind by its share of the rank (rpg_map_location_kinds or rpg_map_landmark_kinds: weight), and
-- the third and fourth how tall and how wide (all rpg_map_site_what); the second says whether it stands, under
-- map_<class>_share_<rank> times how readily that kind stands on p_ground, the ground of the cell of the site on the
-- grid of its rank (as a village is decided by its Region cell), so it is the same seen from any grid.
-- Ranks 1 to 4 also need dry land on their own square (rpg_map_heights_on at the battle grid), so none stands in a lake
-- or the sea the coarse cell hides. None stands inside a place with ground of its own (a haunt, Old Forest, Haven) or
-- within its own half-width of one. Ranks 4 to 6 keep the footprint off the ground of the village, town or city that
-- could grow at a site near it (rpg_map_site: the biggest such a site can hold, rpg_map_town_radius, its edge out by
-- map_town_edge), so none stands in a street; a peak only by its summit.
-- name: its pattern with {A}, a word of the uplands by where it stands (so no two near each other share one), and {B},
-- one of its endings by a roll (Storm + horn: Stormhorn; The Raven Stones; Bleak Tor; Wolf Cave).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     -- what its rolls make it, whatever the ground (rpg_map_site_what), and whether it stands on this ground
     sz AS MATERIALIZED (
       SELECT p_rank AS rank, wt.kind, wt.icon, wt.words, wt.pattern, wt.ends, wt.height AS h, wt.across AS w,
              (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq
         FROM public.rpg_map_site_what(p_class, p_rank, p_rolls) wt
        WHERE (p_rolls[2] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_' || p_class || '_share_' || p_rank)::double precision
                                          * coalesce((wt.grounds ->> p_ground)::double precision, 0)),
     -- dry land under the site (ranks 1 to 4)
     dry AS MATERIALIZED (
       SELECT sz.* FROM sz
        WHERE sz.rank > 4
           OR EXISTS (SELECT 1 FROM (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1) w
                       CROSS JOIN LATERAL public.rpg_map_heights_on(7, 1, mod(mod(p_x, w.span) + w.span, w.span)::integer, p_y::integer, 1, 1) h
                       WHERE h.height >= (SELECT st.value FROM st WHERE st.key = 'map_sea_level'))),
     -- off the ground any village, town or city near it could grow on (ranks 4 to 6)
     tw AS MATERIALIZED (
       SELECT dry.*, CASE WHEN dry.kind = 'peak' THEN 0 ELSE dry.w / dry.sq / 2 END AS r
         FROM dry
        WHERE dry.rank < 4
           OR NOT EXISTS (
                SELECT 1
                  FROM public.rpg_map_lattice() t
                 CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision AS edge) e
                 CROSS JOIN LATERAL generate_series(floor(p_x::double precision / t.lv)::bigint - 1, floor(p_x::double precision / t.lv)::bigint + 1) AS a
                 CROSS JOIN LATERAL generate_series(floor(p_y::double precision / t.lv)::bigint - 1, floor(p_y::double precision / t.lv)::bigint + 1) AS b
                 CROSS JOIN LATERAL public.rpg_map_site(a, b, t.seed, t.lv, t.jit, t.nv, t.nt, t.av, t.at, t.ac) s
                 WHERE sqrt(power(s.x - p_x, 2) + power(s.y - p_y, 2))
                       < CASE WHEN dry.kind = 'peak' THEN 0 ELSE dry.w / dry.sq / 2 END
                         + (1 + e.edge) * CASE WHEN s.city THEN greatest(public.rpg_map_town_radius('city', (SELECT st.value FROM st WHERE st.key = 'map_city_people_high')::integer),
                                                                          public.rpg_map_town_radius('great_city', (SELECT st.value FROM st WHERE st.key = 'map_great_city_people_high')::integer))
                                                WHEN s.town THEN public.rpg_map_town_radius('town', (SELECT st.value FROM st WHERE st.key = 'map_town_people_high')::integer)
                                                ELSE public.rpg_map_town_radius('village', (SELECT st.value FROM st WHERE st.key = 'map_village_people_high')::integer) END)),
     nm AS (SELECT tw.*,
                   -- the word by where its square of its rank lies: a column plus 7 times a row, out of 48, so no two squares
                   -- of a rank within 5 of each other either way share one; the land the landmarks of a grid stand on is 6
                   -- squares of their rank across
                   (ARRAY['Grey', 'Black', 'Raven', 'Eagle', 'Storm', 'Cloud', 'Snow', 'Iron', 'High', 'Old', 'White', 'Red',
                          'Wolf', 'Crow', 'Wind', 'Thunder', 'Frost', 'Stag', 'Hawk', 'Dun', 'Bleak', 'Long', 'Gold', 'Star',
                          'Silver', 'Copper', 'Bright', 'Shadow', 'Ember', 'Ash', 'Bear', 'Boar', 'Fox', 'Owl', 'Heron', 'Falcon',
                          'Moon', 'Sun', 'Dawn', 'Dusk', 'Rain', 'Mist', 'Thorn', 'Bramble', 'Holly', 'Oak', 'Elder', 'King'])
                     [1 + mod(mod(q.qx, 48) + 7 * mod(q.qy, 48), 48)] AS a,
                   tw.ends[1 + mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, cardinality(tw.ends))] AS b
              FROM tw
             CROSS JOIN LATERAL (SELECT floor(mod(mod(p_x, t.a6 * t.l6) + t.a6 * t.l6, t.a6 * t.l6)::double precision / (t.l6 * 12 ^ (6 - p_rank)))::bigint AS qx,
                                        floor(p_y::double precision / (t.l6 * 12 ^ (6 - p_rank)))::bigint AS qy
                                   FROM public.rpg_map_landmark_lattice() t) q)
SELECT nm.kind, nm.icon, nm.words,
       replace(replace(replace(nm.pattern, '{A}{B}', CASE WHEN lower(right(nm.a, 1)) = left(nm.b, 1) THEN nm.a || substr(nm.b, 2) ELSE nm.a || nm.b END),
                       '{A} {B}', nm.a || ' ' || nm.b), '{A}', nm.a),
       nm.h, nm.w
  FROM nm
 CROSS JOIN (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) l
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures c
                    WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL AND c.place_penalty IS NOT NULL
                      AND public.rpg_map_covers(p_x + 0.5::double precision, p_y + 0.5::double precision, c.place_x, c.place_y,
                                                ceil(c.place_w + 2 * nm.r)::integer, ceil(c.place_h + 2 * nm.r)::integer, l.span));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_make(p_rank integer, p_x bigint, p_y bigint, p_rolls integer[], p_ground text)
 RETURNS TABLE(kind text, icon text, words text, name text, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What stands at a landmark site (rpg_map_landmark_sites; step 12b): its landmark, by its first six rolls
-- (rpg_map_site_make, the one home of the sums), or where none stands a place to go into by the next six (step 12c:
-- a cave, a mine, a shrine, a camp or a hut), or nothing. So every landmark stands where it stood before places to go
-- into came, and the two never crowd one site. Worked out when asked, never stored.
WITH lm AS MATERIALIZED (SELECT * FROM public.rpg_map_site_make('landmark', p_rank, p_x, p_y, p_rolls[1:6], p_ground))
SELECT * FROM lm
UNION ALL
SELECT * FROM public.rpg_map_site_make('location', p_rank, p_x, p_y, p_rolls[7:12], p_ground)
 WHERE NOT EXISTS (SELECT 1 FROM lm);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_sites(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, rank integer, x bigint, y bigint, rolls integer[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a landmark could stand on a block of any grid down to the District grid (step 12b), worked out when asked and
-- never stored: the sites of every rank from 1 (the World grid) down to the rank of the grid itself whose spot lies in
-- the block (rpg_map_landmark_site), each with its rank and its rolls (rpg_map_landmark_rolls). A grid of level L
-- shows the landmarks of ranks 1 to L: few on the world, more at each level down (Peter 2026-10-03 17:28). On the
-- battle grid (step 12b2) a block of squares gets the sites of every rank whose landmark could reach into it: the spot
-- within half the width of the widest landmark or place to go into of its rank (rpg_map_landmark_kinds,
-- rpg_map_location_kinds; step 12c), and one square, of the block;
-- whether its own footprint reaches is rpg_map_landmarks. id = mark-<column>-<row> of its rank-6 square, the same seen from any block; x, y =
-- the site in world squares from 0, counted the way the block counts. What stands there is rpg_map_landmark_make.
WITH cfg AS MATERIALIZED (
       SELECT t.*, l.cell::bigint AS cell,
              p_x0::bigint * l.cell AS gx0, (p_x0 + p_cols)::bigint * l.cell AS gx1,
              p_y0::bigint * l.cell AS gy0, (p_y0 + p_rows)::bigint * l.cell AS gy1
         FROM public.rpg_map_landmark_lattice() t CROSS JOIN public.rpg_map_ladder() l
        WHERE l.level = p_level AND p_level BETWEEN 1 AND 7),
     -- how far a site of each rank may stand outside the block: on the battle grid half the width of the widest
     -- landmark of its rank, in squares, and one more; on every other grid nothing
     rr AS (SELECT k.rank AS r, CASE WHEN p_level = 7 THEN ceil(max(k.w_high) / 2 / (SELECT v.value FROM public.rpg_settings v
                                                                                       WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m'))::bigint + 1
                                     ELSE 0 END AS reach
              FROM (SELECT * FROM public.rpg_map_landmark_kinds() UNION ALL SELECT * FROM public.rpg_map_location_kinds()) k
             WHERE k.rank <= least(p_level, 6) GROUP BY k.rank),
     -- the squares of each rank the block reaches
     sq AS (SELECT rr.r, rr.reach, a, b
              FROM cfg CROSS JOIN rr
             CROSS JOIN LATERAL generate_series(floor((cfg.gx0 - rr.reach)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint,
                                                floor((cfg.gx1 + rr.reach - 1)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(greatest(cfg.gy0 - rr.reach, 0)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint,
                                                floor((least(cfg.gy1 + rr.reach, cfg.down) - 1)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint) AS b),
     st AS MATERIALIZED (
       SELECT sq.r, sq.reach, s.w6, s.y6, s.x, s.y
         FROM sq CROSS JOIN cfg
        CROSS JOIN LATERAL public.rpg_map_landmark_site(sq.r, sq.a, sq.b, cfg.seed, cfg.l6, cfg.jit, cfg.a6) s
        WHERE NOT s.picked)
SELECT 'mark-' || st.w6 || '-' || st.y6, st.r, st.x, st.y, public.rpg_map_landmark_rolls(st.w6, st.y6, cfg.seed)
  FROM st CROSS JOIN cfg
 WHERE st.x >= cfg.gx0 - st.reach AND st.x < cfg.gx1 + st.reach AND st.y >= cfg.gy0 - st.reach AND st.y < cfg.gy1 + st.reach;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmarks(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_kinds jsonb)
 RETURNS TABLE(id text, rank integer, kind text, icon text, words text, name text, x bigint, y bigint, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The landmarks a block of any grid down to the District grid shows (step 12b): its sites (rpg_map_landmark_sites)
-- and what stands at each (rpg_map_landmark_make), the one way they are read. A landmark is decided by the ground of
-- the cell its site stands in on the grid of its rank, and a landmark of the World grid by its Continent cell (a World
-- cell is 2,075 miles across and mostly reads as sea), so the same site holds the same landmark seen from any grid.
-- Those cells are read through rpg_map_kinds, which keeps them for the rest of the transaction. p_kinds = the kinds of
-- the cells of this very block when the caller already has them ("x,y": kind, as rpg_map_cells counts them), so its
-- own grid is not worked out twice; else nothing. kind is nothing where no landmark stands.
-- A site is passed over before any ground is read (step 12b2) when neither its landmark nor its place to go into (step
-- 12c) could stand on any ground by its second roll (rpg_map_site_what: the most readily it stands anywhere), and on the
-- battle grid (level 7) when neither footprint, half its width and one square, can reach the block; so the battle grid
-- reads ground only for what may truly stand on it. kind and the rest are a place to go into where no landmark stands
-- and one does (rpg_map_landmark_make).
WITH s AS MATERIALIZED (
       SELECT t.*, greatest(t.rank, 2) AS dl
         FROM public.rpg_map_landmark_sites(p_level, p_x0, p_y0, p_cols, p_rows) t
        CROSS JOIN (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') q
        WHERE EXISTS (
                SELECT 1
                  FROM (VALUES ('landmark', t.rolls[1:6]), ('location', t.rolls[7:12])) AS c(cl, r)
                 CROSS JOIN LATERAL public.rpg_map_site_what(c.cl, t.rank, c.r) w
                 WHERE (c.r[2] - 0.5) / 100 < (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_' || c.cl || '_share_' || t.rank)::double precision
                                              * (SELECT max(e.value::double precision) FROM jsonb_each_text(w.grounds) e)
                   AND (p_level < 7
                        OR sqrt(power(greatest(p_x0 - t.x, 0, t.x - (p_x0 + p_cols - 1)), 2) + power(greatest(p_y0 - t.y, 0, t.y - (p_y0 + p_rows - 1)), 2))
                           <= w.across / 2 / q.sq + 1))),
     sc AS MATERIALIZED (
       SELECT s.*, floor(s.x::double precision / l.cell)::integer AS cx, floor(s.y::double precision / l.cell)::integer AS cy, l.across::bigint AS across
         FROM s JOIN public.rpg_map_ladder() l ON l.level = s.dl),
     -- the cells of this block, from the caller or read once
     own AS MATERIALIZED (
       SELECT split_part(e.key, ',', 1)::integer AS x, split_part(e.key, ',', 2)::integer AS y, e.value AS kind
         FROM jsonb_each_text(p_kinds) e
       UNION ALL
       SELECT k.x, k.y, k.kind FROM public.rpg_map_kinds(p_level, p_x0, p_y0, p_cols, p_rows) k
        WHERE p_kinds IS NULL AND p_level BETWEEN 2 AND 6 AND EXISTS (SELECT 1 FROM sc WHERE sc.dl = p_level)),
     -- the cells of coarser grids under the sites of coarser ranks, each read once
     far AS MATERIALIZED (
       SELECT d.dl, d.cx, d.cy, k.kind
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE sc.dl <> p_level) d
        CROSS JOIN LATERAL public.rpg_map_kinds(d.dl, mod(mod(d.cx, d.across) + d.across, d.across)::integer, d.cy, 1, 1) k)
SELECT sc.id, sc.rank, m.kind, m.icon, m.words, m.name, sc.x, sc.y, m.height, m.across
  FROM sc
  LEFT JOIN own ON sc.dl = p_level AND own.x = sc.cx AND own.y = sc.cy
  LEFT JOIN far ON far.dl = sc.dl AND far.cx = sc.cx AND far.cy = sc.cy
  LEFT JOIN LATERAL public.rpg_map_landmark_make(sc.rank, sc.x, sc.y, sc.rolls, coalesce(own.kind, far.kind)) m ON true;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_squares(p_id text, p_kind text, p_rank integer, p_x bigint, p_y bigint, p_height double precision, p_across double precision, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- The squares of a block of the battle grid that one landmark stands on (step 12b2; Peter 2026-10-06: landmarks at
-- every layer, the battle grid too), the one home of their shapes. p_x, p_y = its middle square; p_height and p_across
-- in metres as rpg_map_landmark_make rolled them. Each square: part (what it is), angle (how steep) and rise (the metres
-- a climber goes up); rpg_map_landmark_cells turns them into the Climbing roll and the time.
--   tower: a solid round tower as wide as the landmark, sheer, its full height.
--   castle (a fortress, a castle, a tower house): a square keep in the middle, 15 in 100 of the width each way, no
--     less than 8 m and no more than 25 m (Rochester keep 21 m, a tower house 8 to 12 m), its full height; round it a
--     curtain wall at the edge, 3.5 m thick round a fortress, 2.5 m round a castle, 1.5 m round a tower house (the
--     barmkin), 45 in 100 of the height of the keep (35 in 100 round a tower house), with one gate 4 m wide on the side a
--     roll picks (part 16, layer 1631 at its middle).
--   castle of the City grid (a motte): a round earth mound, its side as steep as its height over its half-width.
--   ruins: narrower than 10 m, one broken wall through the middle, the way a roll points it (layer 1632); wider, the
--     walls of rooms 4 to 15 m across (a third of the width) inside its round edge, each length of wall between two
--     corners standing or fallen by a roll (layers 1634 and 1635: 55 in 100 stand), each standing to 30 to 100 in 100
--     of the full height (layers 1636 and 1637), so a ruined castle or chapel is a few broken rooms and a ruined city
--     whole streets of them.
--   stones (a stone circle): one stone a square every 4 m round its ring, no fewer than 9 (Castlerigg, 30 m across, has
--     38 stones, Long Meg, 100 m, 59), the first where layer 1632 points, each 60 to 100 in 100 of the full height
--     (layer 1633), near sheer (85 degrees).
--   stone (a standing stone): the stone itself, near sheer, its full height.
--   rock (a boulder): a round boulder, 60 degrees, its full height. cairn: a round heap of stones, 35 degrees.
--   peak: none; a lone peak is a mark on the grids above, its ground is the mountain itself.
-- The places to go into (step 12c), each with its way in on the side a roll picks (layer 1631 at its middle):
--   hut, shrine: a ring of wall at its edge (every square inside it with a square outside it beside it or corner to
--     corner), sheer, a hut 60 in 100 of its height (to the eaves), a shrine its full height, a door a square and a half
--     wide; inside it floor, the hearth of a hut or the altar of a shrine in the middle. A wayside shrine: a stone cross,
--     near sheer (85 degrees), its full height.
--   cave: a knoll of rock as wide as it is (outcrop, 70 degrees, its full height), its mouth a passage from its edge to
--     its middle, a square and a half wide or 15 in 100 of its width. mine: the same knoll and adit at half its width,
--     round it on the side of the adit its spoil heaps (35 degrees, climbed a square at a time) but for the track out.
--   camp: the hearth in the middle; a war camp a palisade at its edge, sheer, its full height, with a gate 4 m wide, and
--     a tent (2.5 m, 60 degrees) every 5 squares each way inside; a camp of a band or a campsite a ring of tents at 60 in
--     100 of its half-width, one every 5 m, no fewer than 3, its full height, the first where layer 1632 points.
-- A square with no angle (floor, hearth, altar, mouth) is no climb: it is walked like the ground under it.
WITH k AS MATERIALIZED (
       SELECT s.sq, t.seed, w.span AS world, p_across / 2 / s.sq AS r, p_x + 0.5 AS cx, p_y + 0.5 AS cy,
              mod(mod(p_x, w.span) + w.span, w.span)::integer AS wx
         FROM (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') s
        CROSS JOIN public.rpg_map_landmark_lattice() t
        CROSS JOIN (SELECT l.span::bigint AS span FROM public.rpg_map_ladder() l WHERE l.level = 1) w
        WHERE p_kind IS DISTINCT FROM 'peak'),
     -- every square of the block its round edge can reach
     g AS (SELECT gx, gy, gx + 0.5 - k.cx AS dx, gy + 0.5 - k.cy AS dy, sqrt(power(gx + 0.5 - k.cx, 2) + power(gy + 0.5 - k.cy, 2)) AS d,
                  (gx - p_x)::integer AS u, (gy - p_y)::integer AS v
             FROM k
            CROSS JOIN LATERAL generate_series(greatest(p_x0::bigint, floor(k.cx - k.r - 1)::bigint), least((p_x0 + p_cols - 1)::bigint, floor(k.cx + k.r + 1)::bigint)) AS gx
            CROSS JOIN LATERAL generate_series(greatest(p_y0::bigint, floor(k.cy - k.r - 1)::bigint, 0), least((p_y0 + p_rows - 1)::bigint, floor(k.cy + k.r + 1)::bigint)) AS gy),
     -- a castle: its keep, its wall and its gate
     cs AS (SELECT greatest(least(p_across * 0.15, 25), 8) / 2 / k.sq AS kh,
                   greatest(CASE p_rank WHEN 2 THEN 3.5 WHEN 3 THEN 2.5 ELSE 1.5 END / k.sq, 1) AS t,
                   CASE WHEN p_rank = 4 THEN 0.35 ELSE 0.45 END AS wall,
                   2 * pi() * (public.rpg_map_roll(k.seed, 1631, k.wx, p_y::integer) - 0.5) / 100 AS gate, 2 / k.sq AS gw
              FROM k WHERE p_kind = 'castle' AND p_rank BETWEEN 2 AND 4),
     -- ruins: the room size in squares, and the way a lone wall points
     rs AS (SELECT greatest(round(least(15, greatest(4, p_across / 3)) / k.sq), 3)::integer AS s,
                   pi() * (public.rpg_map_roll(k.seed, 1632, k.wx, p_y::integer) - 0.5) / 100 AS th
              FROM k WHERE p_kind = 'ruins'),
     -- a hut, a shrine, a cave, a mine, a war camp: the way its door, mouth or gate faces (step 12c)
     dr AS (SELECT 2 * pi() * (public.rpg_map_roll(k.seed, 1631, k.wx, p_y::integer) - 0.5) / 100 AS m
              FROM k WHERE p_kind IN ('hut', 'shrine', 'cave', 'mine', 'camp')),
     sh AS (
       -- tower, standing stone, boulder, cairn: everything within its round edge (at least its middle square)
       SELECT g.gx, g.gy, CASE p_kind WHEN 'tower' THEN 'tower' WHEN 'stone' THEN 'stone' WHEN 'rock' THEN 'boulder' ELSE 'cairn' END AS part,
              CASE p_kind WHEN 'tower' THEN 90 WHEN 'stone' THEN 85 WHEN 'rock' THEN 60 ELSE 35 END::double precision AS angle, p_height AS rise
         FROM g CROSS JOIN k
        WHERE p_kind IN ('tower', 'stone', 'rock', 'cairn') AND g.d <= greatest(k.r, 0.5)
       UNION ALL
       -- a motte: a round mound
       SELECT g.gx, g.gy, 'mound', degrees(atan(p_height / greatest(k.r * k.sq, 1))), p_height
         FROM g CROSS JOIN k
        WHERE p_kind = 'castle' AND p_rank = 5 AND g.d <= greatest(k.r, 0.5)
       UNION ALL
       -- a castle: the keep, then the curtain wall but for its gate
       SELECT g.gx, g.gy, CASE WHEN abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh THEN 'keep' ELSE 'curtain' END, 90,
              CASE WHEN abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh THEN p_height ELSE p_height * cs.wall END
         FROM g CROSS JOIN k CROSS JOIN cs
        WHERE (abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh)
           OR (g.d <= k.r AND g.d > k.r - cs.t
               AND abs(atan2(sin(atan2(g.dy, g.dx) - cs.gate), cos(atan2(g.dy, g.dx) - cs.gate))) * k.r > cs.gw)
       UNION ALL
       -- ruins narrower than 10 m: one broken wall through the middle
       SELECT g.gx, g.gy, 'ruin', 90, p_height
         FROM g CROSS JOIN k CROSS JOIN rs
        WHERE p_across < 10 AND abs(g.dx * sin(rs.th) - g.dy * cos(rs.th)) <= 0.5 AND abs(g.dx * cos(rs.th) + g.dy * sin(rs.th)) <= greatest(k.r, 0.5)
       UNION ALL
       -- wider ruins: the walls of rooms inside its round edge; a corner stands when either wall through it does
       SELECT q.gx, q.gy, 'ruin', 90, max(q.h)
         FROM (SELECT g.gx, g.gy,
                      CASE WHEN mod(mod(g.u, rs.s) + rs.s, rs.s) = 0
                                AND public.rpg_map_roll(k.seed, 1634, mod(mod(g.gx, k.world) + k.world, k.world)::integer, (p_y + floor(g.v::double precision / rs.s) * rs.s)::integer) <= 55
                           THEN p_height * (0.3 + 0.7 * (public.rpg_map_roll(k.seed, 1636, mod(mod(g.gx, k.world) + k.world, k.world)::integer, (p_y + floor(g.v::double precision / rs.s) * rs.s)::integer) - 0.5) / 100) END AS hv,
                      CASE WHEN mod(mod(g.v, rs.s) + rs.s, rs.s) = 0
                                AND public.rpg_map_roll(k.seed, 1635, mod(mod(p_x + floor(g.u::double precision / rs.s)::bigint * rs.s, k.world) + k.world, k.world)::integer, g.gy::integer) <= 55
                           THEN p_height * (0.3 + 0.7 * (public.rpg_map_roll(k.seed, 1637, mod(mod(p_x + floor(g.u::double precision / rs.s)::bigint * rs.s, k.world) + k.world, k.world)::integer, g.gy::integer) - 0.5) / 100) END AS hh
                 FROM g CROSS JOIN k CROSS JOIN rs
                WHERE p_across >= 10 AND g.d <= k.r) z
        CROSS JOIN LATERAL (VALUES (z.gx, z.gy, z.hv), (z.gx, z.gy, z.hh)) AS q(gx, gy, h)
        WHERE q.h IS NOT NULL
        GROUP BY q.gx, q.gy
       UNION ALL
       -- a stone circle: a stone every 4 m round its ring
       SELECT DISTINCT ON (q.gx, q.gy) q.gx, q.gy, 'stone', 85, q.h
         FROM k
        CROSS JOIN LATERAL generate_series(0, greatest(9, round(2 * pi() * k.r * k.sq / 4)::integer) - 1) AS n
        CROSS JOIN LATERAL (SELECT 2 * pi() * (public.rpg_map_roll(k.seed, 1632, k.wx, p_y::integer) - 0.5) / 100 AS a0,
                                   greatest(9, round(2 * pi() * k.r * k.sq / 4)::integer) AS m) c
        CROSS JOIN LATERAL (SELECT floor(k.cx + k.r * cos(c.a0 + 2 * pi() * n / c.m))::bigint AS gx,
                                   floor(k.cy + k.r * sin(c.a0 + 2 * pi() * n / c.m))::bigint AS gy,
                                   p_height * (0.6 + 0.4 * (public.rpg_map_roll(k.seed, 1633, k.wx + n, p_y::integer) - 0.5) / 100) AS h) q
        WHERE p_kind = 'stones' AND q.gx BETWEEN p_x0 AND p_x0 + p_cols - 1 AND q.gy BETWEEN p_y0 AND p_y0 + p_rows - 1
       UNION ALL
       -- a hut or a shrine: its wall but for the door, its floor, its hearth or altar
       SELECT g.gx, g.gy,
              CASE WHEN e.edge THEN p_kind WHEN g.u = 0 AND g.v = 0 THEN CASE p_kind WHEN 'hut' THEN 'hearth' ELSE 'altar' END ELSE 'floor' END,
              CASE WHEN e.edge THEN 90 END::double precision,
              CASE WHEN e.edge THEN p_height * CASE p_kind WHEN 'hut' THEN 0.6 ELSE 1 END END
         FROM g CROSS JOIN k CROSS JOIN dr
        CROSS JOIN LATERAL (SELECT sqrt(power(abs(g.dx) + 1, 2) + power(abs(g.dy) + 1, 2)) > k.r AS edge) e
        WHERE (p_kind = 'hut' OR (p_kind = 'shrine' AND p_rank < 6)) AND g.d <= k.r
          AND NOT (e.edge AND abs(atan2(sin(atan2(g.dy, g.dx) - dr.m), cos(atan2(g.dy, g.dx) - dr.m))) * k.r <= 0.75)
       UNION ALL
       -- a wayside shrine: its cross
       SELECT g.gx, g.gy, 'cross', 85, p_height
         FROM g
        WHERE p_kind = 'shrine' AND p_rank = 6 AND g.u = 0 AND g.v = 0
       UNION ALL
       -- a cave or a mine: its rock, its mouth, a mine's spoil heaps
       SELECT g.gx, g.gy, CASE WHEN z.mouth THEN 'mouth' WHEN g.d <= y.rc THEN 'outcrop' ELSE 'spoil' END,
              CASE WHEN z.mouth THEN NULL WHEN g.d <= y.rc THEN 70 ELSE 35 END::double precision,
              CASE WHEN z.mouth THEN NULL ELSE p_height END
         FROM g CROSS JOIN k CROSS JOIN dr
        CROSS JOIN LATERAL (SELECT g.dx * cos(dr.m) + g.dy * sin(dr.m) AS a, abs(g.dx * sin(dr.m) - g.dy * cos(dr.m)) AS b,
                                   CASE WHEN p_kind = 'mine' THEN k.r / 2 ELSE k.r END AS rc, greatest(0.75, k.r * 0.15) AS mw) y
        CROSS JOIN LATERAL (SELECT y.a >= -0.5 AND y.a <= y.rc AND y.b <= y.mw AS mouth) z
        WHERE p_kind IN ('cave', 'mine')
          AND (g.d <= greatest(y.rc, 0.5) OR (p_kind = 'mine' AND g.d <= k.r AND y.a > 0.34 * g.d AND y.b > y.mw + 1))
       UNION ALL
       -- a camp: its hearth; a war camp: its palisade but for the gate, and its rows of tents
       SELECT g.gx, g.gy, CASE WHEN g.u = 0 AND g.v = 0 THEN 'hearth' WHEN e.edge THEN 'palisade' ELSE 'tent' END,
              CASE WHEN g.u = 0 AND g.v = 0 THEN NULL WHEN e.edge THEN 90 ELSE 60 END::double precision,
              CASE WHEN g.u = 0 AND g.v = 0 THEN NULL WHEN e.edge THEN p_height ELSE 2.5 END
         FROM g CROSS JOIN k CROSS JOIN dr
        CROSS JOIN LATERAL (SELECT sqrt(power(abs(g.dx) + 1, 2) + power(abs(g.dy) + 1, 2)) > k.r AS edge) e
        WHERE p_kind = 'camp' AND g.d <= k.r
          AND ((g.u = 0 AND g.v = 0)
               OR (p_rank = 4 AND e.edge AND abs(atan2(sin(atan2(g.dy, g.dx) - dr.m), cos(atan2(g.dy, g.dx) - dr.m))) * k.r > 2 / k.sq)
               OR (p_rank = 4 AND g.d <= k.r - 3 AND mod(mod(g.u, 5) + 5, 5) = 0 AND mod(mod(g.v, 5) + 5, 5) = 0))
       UNION ALL
       -- a camp of a band or a campsite: its ring of tents
       SELECT DISTINCT ON (q.gx, q.gy) q.gx, q.gy, 'tent', 60, p_height
         FROM k
        CROSS JOIN LATERAL (SELECT 2 * pi() * (public.rpg_map_roll(k.seed, 1632, k.wx, p_y::integer) - 0.5) / 100 AS a0, 0.6 * k.r AS rt,
                                   greatest(3, round(2 * pi() * 0.6 * k.r * k.sq / 5)::integer) AS m) c
        CROSS JOIN LATERAL generate_series(0, c.m - 1) AS n
        CROSS JOIN LATERAL (SELECT floor(k.cx + c.rt * cos(c.a0 + 2 * pi() * n / c.m))::bigint AS gx,
                                   floor(k.cy + c.rt * sin(c.a0 + 2 * pi() * n / c.m))::bigint AS gy) q
        WHERE p_kind = 'camp' AND p_rank > 4 AND q.gx BETWEEN p_x0 AND p_x0 + p_cols - 1 AND q.gy BETWEEN p_y0 AND p_y0 + p_rows - 1)
SELECT sh.gx::integer, sh.gy::integer, p_id, sh.part, sh.angle, sh.rise FROM sh;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid a landmark stands on (step 12b2): the landmarks whose footprint reaches
-- each battle grid of it (rpg_map_landmarks at the battle grid) and their shapes (rpg_map_landmark_squares), each
-- square climbed by the Climbing rule as a wall or a roof is (Peter 2026-10-03 23:12: any steep surface): a wall, a
-- tower, a keep, a standing stone or a boulder climbs its whole height at once (rpg_map_climb_by: a castle wall 13 m,
-- sheer, difficulty 10), the side of a motte or a cairn one square at a time like rock of its slope (rpg_map_climb).
-- Returns what rpg_map_building_cells returns, which reads it with the houses, so the costs, a climb, where a walk
-- ends, where a creature is set down and the Maps tab all see a landmark the way they see a house. The places to go
-- into stand the same way (step 12c): a wall, a cross, a rock outcrop, a palisade or a tent climbs its whole height at
-- once, a spoil heap a square at a time; the floor, hearth or altar inside and the mouth of a cave or mine come with
-- no angle and no climb (the Maps tab draws them; rpg_map_building_cells leaves them out).
-- One read of the map asks for the same squares again and again (a walk, a fight board, one square at a time), so each
-- battle grid has its squares kept in a setting of the transaction (rpg.lmcells, by "x,y" of the battle grid) and gone
-- when it ends; nothing is stored.
DECLARE
  v_all jsonb;
  v_new jsonb := '{}';
  v_c jsonb;
  g record;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.lmcells', true), ''), '{}')::jsonb;
  FOR g IN SELECT a AS gx, b AS gy
             FROM generate_series(floor(p_x0::double precision / 12)::integer, floor((p_x0 + p_cols - 1)::double precision / 12)::integer) AS a
            CROSS JOIN generate_series(floor(p_y0::double precision / 12)::integer, floor((p_y0 + p_rows - 1)::double precision / 12)::integer) AS b LOOP
    IF NOT v_all ? (g.gx || ',' || g.gy) THEN
      SELECT coalesce(jsonb_agg(jsonb_build_array(s.x, s.y, s.id, s.part, s.angle, c.rise, c.difficulty, c.pct)), '[]'::jsonb) INTO v_c
        FROM public.rpg_map_landmarks(7, g.gx * 12, g.gy * 12, 12, 12, NULL) l
       CROSS JOIN LATERAL public.rpg_map_landmark_squares(l.id, l.kind, l.rank, l.x, l.y, l.height, l.across, g.gx * 12, g.gy * 12, 12, 12) s
       CROSS JOIN LATERAL (SELECT b.rise, b.difficulty, b.pct FROM public.rpg_map_climb_by(s.angle, s.rise) b WHERE s.part NOT IN ('mound', 'cairn', 'spoil')
                           UNION ALL
                           SELECT b.rise, b.difficulty, b.pct FROM public.rpg_map_climb(s.angle) b WHERE s.part IN ('mound', 'cairn', 'spoil')
                           UNION ALL
                           SELECT NULL::double precision, NULL::numeric, NULL::integer WHERE s.angle IS NULL) c
       WHERE l.kind IS NOT NULL;
      v_new := v_new || jsonb_build_object(g.gx || ',' || g.gy, v_c);
    END IF;
  END LOOP;
  IF v_new <> '{}'::jsonb THEN
    v_all := v_all || v_new;
    PERFORM set_config('rpg.lmcells', v_all::text, true);
  END IF;
  RETURN QUERY
  SELECT (e ->> 0)::integer, (e ->> 1)::integer, e ->> 2, e ->> 3, (e ->> 4)::double precision, (e ->> 5)::double precision, (e ->> 6)::numeric, (e ->> 7)::integer
    FROM generate_series(floor(p_x0::double precision / 12)::integer, floor((p_x0 + p_cols - 1)::double precision / 12)::integer) AS a
   CROSS JOIN generate_series(floor(p_y0::double precision / 12)::integer, floor((p_y0 + p_rows - 1)::double precision / 12)::integer) AS b
   CROSS JOIN LATERAL jsonb_array_elements(v_all -> (a || ',' || b)) AS e
   WHERE (e ->> 0)::integer BETWEEN p_x0 AND p_x0 + p_cols - 1 AND (e ->> 1)::integer BETWEEN p_y0 AND p_y0 + p_rows - 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_building_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that a house stands on (step 8c; rpg_map_buildings, the one home of where
-- houses stand): every square whose middle lies inside one. The squares along its edge (within one square of it) are
-- its walls, the rest its roof. Each is a steep surface, climbed by the Climbing rule (rpg_map_climb_by, Peter
-- 2026-10-03 23:12: the climbing rule goes for any steep surface, buildings too): a wall is sheer (90 degrees,
-- difficulty 10) and climbs the house's height to the eaves; a roof square climbs like rock of the roof's pitch, one
-- square's worth (rpg_map_climb: thatch at 50 degrees 1.33 m, difficulty 2.5). angle = how steep, rise = metres
-- climbed, difficulty of the Climbing roll, pct = the percent of time it adds to the square. Ground underneath is
-- whatever rpg_map_cells says (the settlement's streets and yards); the house stands on it, the way a cliff is a steep
-- part of the mountains. The costs of a block (rpg_map_costs), the climb on a move (rpg_climb_check), where a walk may
-- end (rpg_map_walk), where a creature is set down (rpg_map_set_down) and the Maps tab all read it.
-- The squares a landmark stands on come with them (step 12b2; rpg_map_landmark_cells): a castle wall, a keep, a tower, a
-- ruined wall, a standing stone, a boulder, a cairn or the side of a motte, each climbed the same way, its id the
-- id of the landmark (mark-<x>-<y>); and those of a place to go into (step 12c), but for its squares with no climb
-- (a floor, a hearth, an altar, a mouth), which are walked like the ground.
WITH h AS MATERIALIZED (
       SELECT b.*, cw.rise AS w_rise, cw.difficulty AS w_dif, cw.pct AS w_pct, cr.rise AS r_rise, cr.difficulty AS r_dif, cr.pct AS r_pct
         FROM public.rpg_map_buildings(p_level, p_x0, p_y0, p_cols, p_rows) b
        CROSS JOIN LATERAL public.rpg_map_climb_by(90, b.eaves) cw
        CROSS JOIN LATERAL public.rpg_map_climb(b.pitch) cr)
SELECT gx, gy, h.id, CASE WHEN q.wall THEN 'wall' ELSE 'roof' END, CASE WHEN q.wall THEN 90 ELSE h.pitch END,
       CASE WHEN q.wall THEN h.w_rise ELSE h.r_rise END, CASE WHEN q.wall THEN h.w_dif ELSE h.r_dif END, CASE WHEN q.wall THEN h.w_pct ELSE h.r_pct END
  FROM h
 CROSS JOIN LATERAL (SELECT h.half_len * abs(h.ux) + h.half_wide * abs(h.uy) AS ex, h.half_len * abs(h.uy) + h.half_wide * abs(h.ux) AS ey) e
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(h.cx - e.ex)::integer), least(p_x0 + p_cols - 1, floor(h.cx + e.ex)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(h.cy - e.ey)::integer), least(p_y0 + p_rows - 1, floor(h.cy + e.ey)::integer)) AS gy
 -- the middle of the square, measured along the house and across it
 CROSS JOIN LATERAL (SELECT (gx + 0.5 - h.cx) * h.ux + (gy + 0.5 - h.cy) * h.uy AS a, (gy + 0.5 - h.cy) * h.ux - (gx + 0.5 - h.cx) * h.uy AS b) l
 CROSS JOIN LATERAL (SELECT abs(l.a) > h.half_len - 1 OR abs(l.b) > h.half_wide - 1 AS wall) q
 WHERE abs(l.a) <= h.half_len AND abs(l.b) <= h.half_wide
UNION ALL
SELECT m.x, m.y, m.id, m.part, m.angle, m.rise, m.difficulty, m.pct
  FROM public.rpg_map_landmark_cells(p_level, p_x0, p_y0, p_cols, p_rows) m
 WHERE m.angle IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climb_words(p_part text, p_angle double precision)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What a steep square is, in words (step 12b2), the one home of them: the wall or the roof of a house (step 8c), the
-- parts of a landmark or a place to go into (rpg_map_landmark_squares; step 12c), or a cliff (part nothing). Read by the climb on a move
-- (rpg_climb_check) and by the Maps tab (rpg_map_view_block: the climb of each cell).
SELECT CASE p_part WHEN 'wall' THEN 'the wall of a house' WHEN 'roof' THEN 'a ' || round(p_angle) || '-degree roof'
                   WHEN 'keep' THEN 'the keep of a castle' WHEN 'curtain' THEN 'the wall of a castle' WHEN 'tower' THEN 'a stone tower'
                   WHEN 'ruin' THEN 'a ruined wall' WHEN 'stone' THEN 'a standing stone' WHEN 'boulder' THEN 'a boulder'
                   WHEN 'cairn' THEN 'a cairn' WHEN 'mound' THEN 'the side of a motte'
                   WHEN 'hut' THEN 'the wall of a hut' WHEN 'shrine' THEN 'the wall of a shrine' WHEN 'cross' THEN 'a wayside cross'
                   WHEN 'outcrop' THEN 'a rock outcrop' WHEN 'spoil' THEN 'a spoil heap' WHEN 'palisade' THEN 'a palisade'
                   WHEN 'tent' THEN 'a tent'
                   ELSE 'a ' || round(p_angle) || '-degree cliff' END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_icons()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp) are symbols too. So are
-- a town and a city (step 8: the villages, towns and cities that grow on the land, rpg_map_towns), a great city
-- (step 12a), and the landmarks (step 12b, rpg_map_landmark_kinds): a peak, a castle, a tower, a stone circle, a
-- standing stone, a boulder and a cairn (ruins was already one), and the places to go into (step 12c,
-- rpg_map_location_kinds): a cave, a mine, a shrine, a camp and a hut.
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'town', 'city', 'great_city',
             'peak', 'castle', 'tower', 'stones', 'stone', 'rock', 'cairn', 'cave', 'mine', 'shrine', 'camp', 'hut'];
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_entry(p_id text, p_rank integer, p_kind text, p_icon text, p_words text, p_name text, p_x bigint, p_y bigint, p_height double precision, p_across double precision, p_level integer, p_gx0 bigint, p_gy0 bigint, p_gx1 bigint, p_gy1 bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How the Maps tab is told about a landmark (rpg_map_view_block; step 12b), the one home of it, the way it is told about
-- a village, town or city: id, name, kind (what it is), icon (its map symbol), landmark = true, level (what the map calls
-- it), rank (the coarsest grid that shows it), size (how tall it stands, or for a peak how far it rises above the land
-- round it, how far across it is, and how far off it can be made out, rpg_map_landmark_sight), view = the grid it
-- opens, the grid of the coarsest level whose cells are no more than twice as wide as it (from the Continent grid to
-- the District grid), listed = false (the sidebar keeps the landmarks in a list of their own), location = true for a
-- place to go into (step 12c; rpg_map_location_kinds), which the sidebar lists apart, spot = where it sits on
-- the grid p_level whose block runs from square p_gx0, p_gy0 up to p_gx1, p_gy1: its middle from the top-left corner and
-- its width and height, in thousandths of a cell, or nothing when its middle is off the block.
SELECT jsonb_strip_nulls(jsonb_build_object(
         'id', p_id, 'name', p_name, 'kind', p_kind, 'icon', p_icon, 'landmark', true, 'level', p_words, 'rank', p_rank,
         'size', CASE WHEN p_kind = 'peak' THEN 'rises ' ELSE '' END || to_char(round(p_height / 0.3048), 'FM999,999') || ' feet'
                 || CASE WHEN p_kind = 'peak' THEN ', ' ELSE ' tall, ' END || public.rpg_map_length_text(round(p_across / q.sq)::numeric) || ' across, '
                 || 'seen from about ' || public.rpg_map_length_text(round(public.rpg_map_landmark_sight(p_height))::numeric),
         'view', o.level::text || '-' || mod(mod(floor(p_x::double precision / o.up)::bigint, o.across) + o.across, o.across)::text || '-' || floor(p_y::double precision / o.up)::bigint::text,
         'listed', false,
         'location', CASE WHEN EXISTS (SELECT 1 FROM public.rpg_map_location_kinds() k WHERE k.rank = p_rank AND k.kind = p_kind) THEN true END,
         'spot', CASE WHEN p_x >= p_gx0 AND p_x < p_gx1 AND p_y >= p_gy0 AND p_y < p_gy1
                      THEN jsonb_build_array(((p_x - p_gx0) * 1000 + g.cell / 2) / g.cell, ((p_y - p_gy0) * 1000 + g.cell / 2) / g.cell,
                                             (round(p_across / q.sq)::bigint * 1000 + g.cell / 2) / g.cell, (round(p_across / q.sq)::bigint * 1000 + g.cell / 2) / g.cell) END))
  FROM (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_square_m')::double precision AS sq) q
 CROSS JOIN (SELECT l.cell::bigint AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) g
 -- the grid it opens, and the cells of the grid above it (a grid is named by the cell of the grid above that holds it)
 CROSS JOIN LATERAL (SELECT l.level, u.cell::bigint AS up, u.across::bigint AS across
                       FROM public.rpg_map_ladder() l JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
                      WHERE l.level BETWEEN 2 AND 6 AND (l.cell <= 2 * p_across / q.sq OR l.level = 6)
                      ORDER BY l.level LIMIT 1) o;
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
-- landmarks = the landmarks the read shows (step 12b; rpg_map_landmarks), from the World grid down to the District grid:
-- each grid those of its own rank and every rank above it, few on the world and more each level down (Peter
-- 2026-10-03 17:28), each a mark in the cell its middle stands in (its id among the marks of that cell; a grid drawn
-- fine carries it in the marks of its detail), told as rpg_map_landmark_entry tells it. The kids login sees a
-- landmark when its cell is found or known, or from as far off as it can be made out (rpg_map_landmark_sight) of where
-- a player character walked, since things seen and steered by from far are what landmarks are (Peter 2026-10-06): a
-- landmark seen that way is marked even in a cell not found yet. The battle grid has none here.
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
  v_lands     jsonb;
  v_lmk       jsonb;
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
         SELECT lv.*, lv.near OR EXISTS (SELECT 1 FROM tr CROSS JOIN LATERAL (SELECT mod(mod(lv.x, v_world) + v_world, v_world) + 1 AS wx) w
                                         WHERE public.rpg_seg_box(tr.x0, tr.y0, tr.x1, tr.y1, w.wx - lv.sight, lv.y + 1 - lv.sight, w.wx + lv.sight, lv.y + 1 + lv.sight)) AS shown
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
       -- the battle grid: the squares of a place to go into walked like the ground (step 12c), one each
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND f.angle IS NULL ORDER BY f.x, f.y, f.part),
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
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
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
         -- the landmarks shown (step 12b), biggest first
         (SELECT jsonb_agg(public.rpg_map_landmark_entry(ls.id, ls.rank, ls.kind, ls.icon, ls.words, ls.name, ls.x, ls.y, ls.height, ls.across,
                                                         v_l.level, v_gx0, v_gy0, v_gx1, v_gy1) ORDER BY ls.rank, ls.name)
            FROM ls WHERE ls.shown),
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_lands, v_lmk;

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
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- the new functions run only inside the map reads (granted like the other map helpers: the service role only)
REVOKE ALL ON FUNCTION public.rpg_map_location_kinds() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_location_kinds() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_site_what(text, integer, integer[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_site_what(text, integer, integer[]) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_site_make(text, integer, bigint, bigint, integer[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_site_make(text, integer, bigint, bigint, integer[], text) TO service_role;

-- the rule card (step 12c): places to go into
UPDATE public.rpg_rules
   SET body = replace(body,
                'a slip drops her 5.4 m for 6 damage.*',
                'a slip drops her 5.4 m for 6 damage.*' || chr(10) || chr(10)
                || 'Places to go into are smaller: caves, mines, shrines, camps and huts, rolled where no landmark stands. The Region grid shows great caves, mine workings and war camps, the City grid caves, mines, shrines, camps and huts, the District grid hollows, wayside shrines, campsites and huts. Caves and mines lie in mountains and hills, camps in woods and on open land, shrines and huts on any dry ground. On the battle grid each has its way in: a hut or a shrine its door, a cave or a mine its mouth, a war camp its gate. Their walls, rock, palisades and tents are climbed like the wall of a house, a spoil heap like a slope of rock; the floor inside is walked like the ground.' || chr(10)
                || '*A hut 6 m across and 4 m tall is 5 squares wide: a ring of wall to the eaves, 2.4 m and sheer (Climbing against 10), round 5 squares of floor with the hearth in the middle, and one square of door.*'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('a slip drops her 5.4 m for 6 damage.*' IN body) > 0
   AND position('Places to go into are smaller' IN body) = 0;

