-- roleplaying map step 12b: landmarks at every layer (Peter 2026-10-03 17:28: choice landmarks at every layer, few on
-- the world, more each level down; 2026-10-06 17:21 / 17:52: things seen and steered by from far: lone peaks, castles,
-- ruins, towers, standing stones). Settings map_landmark_*; new rpg_map_landmark_kinds, rpg_map_landmark_lattice,
-- rpg_map_landmark_site, rpg_map_landmark_rolls, rpg_map_landmark_sites, rpg_map_landmark_sight, rpg_map_landmark_make,
-- rpg_map_landmarks, rpg_map_landmark_entry; rpg_map_icons (the landmark symbols), rpg_map_view_block (landmarks on every
-- grid down to the District grid, seen from far by the kids login); rule card world_map. No drops, no table changes.

-- step 12b: landmarks at every layer (Peter 2026-10-03 17:28, 2026-10-06 17:21 / 17:52)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label
  FROM (VALUES ('map_landmark_lattice', 24::numeric, 'Landmarks: each square this many squares across (88 feet, 2 District cells) holds one site where a landmark of the District grid could stand; each rank above is 12 times as wide (2 cells of its own grid) and picks one of the sites of the rank below'),
               ('map_landmark_jitter', 0.6, 'Landmarks: the middle share of its square a site stands in, each way'),
               ('map_landmark_share_1', 0.8, 'Landmarks: share of World-grid sites (one in 2 x 2 World cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_share_2', 0.45, 'Landmarks: share of Continent-grid sites (one in 2 x 2 Continent cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_share_3', 0.4, 'Landmarks: share of Country-grid sites (one in 2 x 2 Country cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_share_4', 0.35, 'Landmarks: share of Region-grid sites (one in 2 x 2 Region cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_share_5', 0.3, 'Landmarks: share of City-grid sites (one in 2 x 2 City cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_share_6', 0.25, 'Landmarks: share of District-grid sites (one in 2 x 2 District cells) where a landmark stands, on the best ground for it'),
               ('map_landmark_arcmin', 5, 'Landmarks: the smallest a thing can span, in minutes of arc, and still be made out (the letters of the Snellen eye chart span 5)')) AS v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = v.key);

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_kinds()
 RETURNS TABLE(rank integer, kind text, icon text, words text, weight double precision, h_low double precision, h_high double precision, w_low double precision, w_high double precision, pattern text, ends text[], grounds jsonb)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The landmarks of the world map (step 12b; Peter 2026-10-03 17:28: choice landmarks at every layer, few on the world,
-- more each level down; 2026-10-06: things seen and steered by from far: lone peaks, castles, ruins, towers, standing
-- stones), the one home of what each can be. rank = the coarsest grid that shows it (1 the World grid to 6 the District
-- grid; a landmark shows on every grid from its rank down); kind and icon = what it is and its map symbol (rpg_map_icons);
-- words = what the map calls it; weight = its share of the landmarks of its rank (the weights of a rank add up to 1);
-- h_low, h_high = how tall it stands, in metres (a peak: how far it rises above the land round it, its prominence);
-- w_low, w_high = how far across it is, in metres; both rolled on a doubling scale between them, as many small as big;
-- pattern = its name, {A} a word of the uplands and {B} one of ends; grounds = how readily it stands on each kind of
-- ground of the cell of its rank (1 as readily as anywhere, 0 or missing never). Worked out when asked, never stored.
-- Each rank is about one grid bigger than the next: a landmark of a rank is about as big as the cell of the
-- grid two levels finer, and is seen about as far as a cell of its own grid or more (rpg_map_landmark_sight).
-- The sizes are of real ones: a lone great peak, Kilimanjaro, rises 5,885 m on a base 60 km across, Mount Rainier
-- 4,026 m, Etna 3,357 m, Ben Nevis 1,345 m, Glastonbury Tor 145 m; a ruined city, Angkor, spreads 8 km, its
-- temple 65 m tall; a great fortress, the walled Cite of Carcassonne, is about 600 m across, Krak des Chevaliers
-- 210 m; a castle keep stands 25 to 35 m (Rochester 34 m) in a bailey 80 to 250 m across; a tower house 15 to 25 m;
-- a motte 8 to 15 m on a base 30 to 60 m (motte-and-bailey castles, 11th to 12th century); a great tower, the
-- Roman lighthouse of A Coruna, 55 m; a watchtower 15 to 30 m; a fire beacon 6 to 12 m; a stone circle 30 to 110 m
-- across of stones 2 to 5 m (Castlerigg 30 m, Long Meg 100 m); a great standing stone 4 to 8 m (Rudston 7.6 m);
-- a standing stone 1.2 to 3.5 m; a cairn 1 to 3 m.
-- Peaks stand on mountains (and hills, from the Region grid down); a great peak or a peak of the Continent grid may also
-- rise alone from open land, as the great volcanoes do (Kilimanjaro from savanna, Fuji, Ararat, Elbrus), less readily;
-- castles on good farmland as villages do, readily on hills; ruins anywhere dry, most of all in forest, jungle and
-- desert where nobody rebuilt; towers and stone circles on open land and uplands (most British stone circles stand on
-- moor and upland); cairns on hills, mountains and tundra.
-- Nothing stands in the sea, in water, on snow and ice, on a road or a street, or inside a place with ground of its own.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (1, 'peak',   'peak',   'Great peak',      0.6,  4500, 6000, 30000, 60000, '{A}{B}',            ARRAY['horn', 'peak', 'spire'],           '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2}'),
    (1, 'ruins',  'ruins',  'Ruined city',     0.4,    40,   70,  3000,  9000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (2, 'peak',   'peak',   'Peak',            0.45, 2500, 4500, 15000, 40000, '{A}{B}',            ARRAY['horn', 'pike', 'fell'],            '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2}'),
    (2, 'castle', 'castle', 'Fortress',        0.3,    30,   50,   400,  1200, 'The Fortress of {A}{B}', ARRAY['hold', 'gard', 'mont', 'crest'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1}'),
    (2, 'ruins',  'ruins',  'Ruined city',     0.25,   20,   45,  1000,  3000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (3, 'peak',   'peak',   'Mountain',        0.3,   800, 2500,  4000, 15000, '{A}{B}',            ARRAY['fell', 'pike', 'crag', 'howe'],    '{"mountains": 1}'),
    (3, 'castle', 'castle', 'Castle',          0.3,    25,   35,    80,   250, '{A}{B} Castle',     ARRAY['hold', 'gard', 'mont', 'crest', 'wall', 'keep'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1}'),
    (3, 'ruins',  'ruins',  'Ruined castle',   0.2,    15,   30,    60,   200, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'wall', 'keep'],  '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (3, 'tower',  'tower',  'Great tower',     0.2,    35,   60,    10,    18, '{A} Tower',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3}'),
    (4, 'peak',   'peak',   'Hill',            0.2,   150,  800,   800,  4000, '{A} {B}',           ARRAY['Tor', 'Fell', 'Howe', 'Law', 'Knott'], '{"mountains": 1, "hills": 1}'),
    (4, 'castle', 'castle', 'Tower house',     0.15,   15,   25,    20,    60, '{A}{B} Keep',       ARRAY['hold', 'gard', 'mont', 'crest', 'wall'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1}'),
    (4, 'ruins',  'ruins',  'Ruined chapel',   0.2,     8,   20,    10,    30, '{A} Chapel',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (4, 'tower',  'tower',  'Watchtower',      0.2,    15,   30,     6,    10, '{A} Watch',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3}'),
    (4, 'stones', 'stones', 'Stone circle',    0.25,    2,    5,    30,   110, 'The {A} Stones',    ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2}'),
    (5, 'peak',   'peak',   'Crag',            0.2,    30,  150,   100,   600, '{A} {B}',           ARRAY['Crag', 'Scar', 'Knott', 'Nab'],    '{"mountains": 1, "hills": 1}'),
    (5, 'castle', 'castle', 'Motte',           0.1,     8,   15,    30,    60, '{A} Mount',         ARRAY[''],                                '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1}'),
    (5, 'ruins',  'ruins',  'Ruined croft',    0.25,    3,    6,     6,    15, '{A} Croft',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (5, 'tower',  'tower',  'Beacon',          0.15,    6,   12,     3,     6, '{A} Beacon',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3}'),
    (5, 'stone',  'stone',  'Great standing stone', 0.3, 4,   8,     1,   2.5, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2}'),
    (6, 'rock',   'rock',   'Boulder',         0.35,    2,    8,     3,    12, '{A} Rock',          ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.7, "desert": 0.6, "land": 0.5, "plains": 0.4, "forest": 0.4, "pine": 0.4}'),
    (6, 'ruins',  'ruins',  'Broken wall',     0.2,   1.5,    4,     2,     8, '{A} Wall',          ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4}'),
    (6, 'stone',  'stone',  'Standing stone',  0.3,   1.2,  3.5,   0.5,   1.2, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2}'),
    (6, 'cairn',  'cairn',  'Cairn',           0.15,    1,    3,     2,     6, '{A} Cairn',         ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.8, "desert": 0.4, "land": 0.3, "plains": 0.3, "pine": 0.2}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_lattice()
 RETURNS TABLE(seed integer, l6 bigint, jit double precision, a6 bigint, down bigint)
 LANGUAGE sql
 STABLE
AS $function$
-- The numbers of the lattice landmarks stand on (step 12b), the one home of them: seed = the map seed; l6 = squares
-- across a landmark square of the District grid (map_landmark_lattice, 24: 2 District cells, 88 feet); jit = the middle
-- share of that square a site sits in (map_landmark_jitter); a6 = those squares round the world; down = squares from
-- pole to pole. Each rank above is 12 times as wide (2 cells of its own grid). Plain SQL with nothing set of its own,
-- so a caller reads it as part of its own query; its callers run with the rights of their owner.
SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = l.agency_id AND s.key = 'map_seed')::integer,
       l.value::bigint,
       (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = l.agency_id AND s.key = 'map_landmark_jitter')::double precision,
       w.span::bigint / l.value::bigint, w.span::bigint / 2
  FROM public.rpg_settings l
 CROSS JOIN (SELECT d.span FROM public.rpg_map_ladder() d WHERE d.level = 1) w
 WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND l.key = 'map_landmark_lattice';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_site(p_rank integer, p_sx bigint, p_sy bigint, p_seed integer, p_l6 bigint, p_jit double precision, p_a6 bigint)
 RETURNS TABLE(w6 bigint, y6 bigint, x bigint, y bigint, picked boolean)
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
-- The site of one landmark square (step 12b): the one home of where a landmark stands. The world is cut into landmark
-- squares at six ranks, rank 6 p_l6 squares across (2 District cells) and each rank above 12 times as wide (2 cells of
-- its own grid; rank 1 is 2 World cells), so a square of each rank holds 12 x 12 squares of the rank below. Each square
-- of ranks 1 to 5 picks one of its 144 by two fixed-seed rolls (rpg_map_roll part 16, layers 1612 + 2 x rank and
-- 1613 + 2 x rank at the square, its column counted round the world), and so on down to rank 6, as central place
-- theory nests market towns (Christaller 1933): the site of a square is the site of the rank-6 square its picks lead to,
-- at a steady spot within the middle p_jit of it each way (layers 1601 and 1602). A square picked by the square above
-- it shares the site of that square, so it is a site of the rank above, not of its own (picked); every other square holds
-- one site of its own rank, and no two landmarks ever share a spot.
-- w6, y6 = the rank-6 square of the site (its column counted round the world; the id of the site is mark-<w6>-<y6>);
-- x, y = the site in world squares from 0, counted the way p_sx counts (a square past the east or west end keeps its
-- own count). What stands there is rpg_map_landmark_make.
DECLARE
  v_q  integer;
  v_a  bigint;
  v_w  bigint;
  v_k  integer;
  v_cx bigint := p_sx;
  v_cy bigint := p_sy;
  v_px bigint;
  v_py bigint;
BEGIN
  picked := false;
  IF p_rank > 1 THEN
    v_px := floor(p_sx::double precision / 12)::bigint;
    v_py := floor(p_sy::double precision / 12)::bigint;
    v_a := p_a6 / (12 ^ (7 - p_rank))::bigint;
    v_w := mod(mod(v_px, v_a) + v_a, v_a);
    v_k := mod((public.rpg_map_roll(p_seed, 1612 + 2 * (p_rank - 1), v_w::integer, v_py::integer) - 1) * 100
               + public.rpg_map_roll(p_seed, 1613 + 2 * (p_rank - 1), v_w::integer, v_py::integer) - 1, 144);
    picked := v_px * 12 + mod(v_k, 12) = p_sx AND v_py * 12 + v_k / 12 = p_sy;
  END IF;
  FOR v_q IN p_rank .. 5 LOOP
    v_a := p_a6 / (12 ^ (6 - v_q))::bigint;
    v_w := mod(mod(v_cx, v_a) + v_a, v_a);
    v_k := mod((public.rpg_map_roll(p_seed, 1612 + 2 * v_q, v_w::integer, v_cy::integer) - 1) * 100
               + public.rpg_map_roll(p_seed, 1613 + 2 * v_q, v_w::integer, v_cy::integer) - 1, 144);
    v_cx := v_cx * 12 + mod(v_k, 12);
    v_cy := v_cy * 12 + v_k / 12;
  END LOOP;
  w6 := mod(mod(v_cx, p_a6) + p_a6, p_a6);
  y6 := v_cy;
  x := v_cx * p_l6 + floor(p_l6 * ((1 - p_jit) / 2 + p_jit * (public.rpg_map_roll(p_seed, 1601, w6::integer, y6::integer) - 0.5) / 100))::bigint;
  y := v_cy * p_l6 + floor(p_l6 * ((1 - p_jit) / 2 + p_jit * (public.rpg_map_roll(p_seed, 1602, w6::integer, y6::integer) - 0.5) / 100))::bigint;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_rolls(p_w6 bigint, p_y6 bigint, p_seed integer)
 RETURNS integer[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The fixed-seed d100s of a landmark site (step 12b; rpg_map_roll part 16, layers 1621 to 1626 at its rank-6 square,
-- its column counted round the world): which kind it is, whether it stands, how tall, how wide, and the ending of its
-- name (2). The one home of them; what they mean is rpg_map_landmark_make.
SELECT ARRAY(SELECT public.rpg_map_roll(p_seed, 1620 + n, p_w6::integer, p_y6::integer) FROM generate_series(1, 6) AS n ORDER BY n);
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
-- shows the landmarks of ranks 1 to L: few on the world, more at each level down (Peter 2026-10-03 17:28). The
-- battle grid shows none here. id = mark-<column>-<row> of its rank-6 square, the same seen from any block; x, y =
-- the site in world squares from 0, counted the way the block counts. What stands there is rpg_map_landmark_make.
WITH cfg AS MATERIALIZED (
       SELECT t.*, l.cell::bigint AS cell,
              p_x0::bigint * l.cell AS gx0, (p_x0 + p_cols)::bigint * l.cell AS gx1,
              p_y0::bigint * l.cell AS gy0, (p_y0 + p_rows)::bigint * l.cell AS gy1
         FROM public.rpg_map_landmark_lattice() t CROSS JOIN public.rpg_map_ladder() l
        WHERE l.level = p_level AND p_level BETWEEN 1 AND 6),
     -- the squares of each rank the block reaches
     sq AS (SELECT r.r, a, b
              FROM cfg
             CROSS JOIN generate_series(1, p_level) AS r(r)
             CROSS JOIN LATERAL generate_series(floor(cfg.gx0::double precision / (cfg.l6 * (12 ^ (6 - r.r)))::bigint)::bigint,
                                                floor((cfg.gx1 - 1)::double precision / (cfg.l6 * (12 ^ (6 - r.r)))::bigint)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(greatest(cfg.gy0, 0)::double precision / (cfg.l6 * (12 ^ (6 - r.r)))::bigint)::bigint,
                                                floor((least(cfg.gy1, cfg.down) - 1)::double precision / (cfg.l6 * (12 ^ (6 - r.r)))::bigint)::bigint) AS b),
     st AS MATERIALIZED (
       SELECT sq.r, s.w6, s.y6, s.x, s.y
         FROM sq CROSS JOIN cfg
        CROSS JOIN LATERAL public.rpg_map_landmark_site(sq.r, sq.a, sq.b, cfg.seed, cfg.l6, cfg.jit, cfg.a6) s
        WHERE NOT s.picked)
SELECT 'mark-' || st.w6 || '-' || st.y6, st.r, st.x, st.y, public.rpg_map_landmark_rolls(st.w6, st.y6, cfg.seed)
  FROM st CROSS JOIN cfg
 WHERE st.x >= cfg.gx0 AND st.x < cfg.gx1 AND st.y >= cfg.gy0 AND st.y < cfg.gy1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_sight(p_height double precision)
 RETURNS double precision
 LANGUAGE sql
 STABLE
AS $function$
-- How far off a landmark p_height metres tall can be made out, in squares (step 12b), the one home of it: the nearer of
-- two distances. The horizon: the eyes of a person see the ground out to sight_squares (2.7 miles, the horizon for eyes
-- about 1.5 m up on a world the size of the Earth), and the top of something h metres tall shows over the horizon
-- from a further root of 2 R h (R the radius of the world, from map_world_miles), so the two add (the distance a
-- lighthouse is seen from a ship, Bowditch). And the eye: a thing is made out when it spans map_landmark_arcmin minutes
-- of arc (5: the size of a letter on the Snellen eye chart), so no farther than h / tan(5 minutes). Plain SQL, read inline.
SELECT least(e.sight + sqrt(2 * e.r * greatest(p_height, 0)) / e.sq,
             greatest(p_height, 0) / tan(radians(e.arcmin / 60)) / e.sq)
  FROM (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'sight_squares')::double precision AS sight,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_world_miles')::double precision * 1609.344 / (2 * pi()) AS r,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_square_m')::double precision AS sq,
               (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_landmark_arcmin')::double precision AS arcmin) e;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_make(p_rank integer, p_x bigint, p_y bigint, p_rolls integer[], p_ground text)
 RETURNS TABLE(kind text, icon text, words text, name text, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What stands at a landmark site (rpg_map_landmark_sites), the one home of it (step 12b): a landmark of its rank or
-- nothing, what kind, how tall and how wide, and its name. Worked out when asked, never stored.
-- The first roll picks the kind by its share of the rank (rpg_map_landmark_kinds: weight); the second says whether it
-- stands, under map_landmark_share_<rank> times how readily that kind stands on p_ground, the ground of the cell of the site
-- on the grid of its rank (as a village is decided by its Region cell), so a landmark is the same seen from any grid.
-- Landmarks of ranks 1 to 4 also need dry land on their own square (rpg_map_heights_on at the battle grid), so none
-- stands in a lake or the sea the coarse cell hides. None stands inside a place with ground of its own (a haunt, Old
-- Forest, Haven) or within its own half-width of one. A landmark of ranks 4 to 6 keeps its footprint off the ground of
-- the village, town or city that could grow at a site near it (rpg_map_site: the biggest such a site can hold,
-- rpg_map_town_radius, its edge out by map_town_edge), so it never stands in a street; a peak only by its summit.
-- height and across: steady rolls from the least to the most of its kind, as many small as big on a doubling scale.
-- name: its pattern with {A}, a word of the uplands by where it stands (so no two near each other share one), and {B},
-- one of its endings by a roll (Storm + horn: Stormhorn; The Raven Stones; Bleak Tor).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     -- the kind its first roll picks
     kd AS MATERIALIZED (
       SELECT q.* FROM (SELECT k.*, sum(k.weight) OVER (ORDER BY k.kind, k.icon) AS cum
                          FROM public.rpg_map_landmark_kinds() k WHERE k.rank = p_rank) q
        WHERE (p_rolls[1] - 0.5) / 100 < q.cum ORDER BY q.cum LIMIT 1),
     -- whether it stands on this ground
     gw AS MATERIALIZED (
       SELECT kd.* FROM kd
        WHERE (p_rolls[2] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_landmark_share_' || p_rank)::double precision
                                          * coalesce((kd.grounds ->> p_ground)::double precision, 0)),
     sz AS MATERIALIZED (
       SELECT gw.*, gw.h_low * power(gw.h_high / gw.h_low, (p_rolls[3] - 0.5) / 100) AS h,
              gw.w_low * power(gw.w_high / gw.w_low, (p_rolls[4] - 0.5) / 100) AS w,
              (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq
         FROM gw),
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
WITH s AS MATERIALIZED (SELECT t.*, greatest(t.rank, 2) AS dl FROM public.rpg_map_landmark_sites(p_level, p_x0, p_y0, p_cols, p_rows) t),
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
-- the District grid), listed = false (the sidebar keeps the landmarks in a list of their own), spot = where it sits on
-- the grid p_level whose block runs from square p_gx0, p_gy0 up to p_gx1, p_gy1: its middle from the top-left corner and
-- its width and height, in thousandths of a cell, or nothing when its middle is off the block.
SELECT jsonb_strip_nulls(jsonb_build_object(
         'id', p_id, 'name', p_name, 'kind', p_kind, 'icon', p_icon, 'landmark', true, 'level', p_words, 'rank', p_rank,
         'size', CASE WHEN p_kind = 'peak' THEN 'rises ' ELSE '' END || to_char(round(p_height / 0.3048), 'FM999,999') || ' feet'
                 || CASE WHEN p_kind = 'peak' THEN ', ' ELSE ' tall, ' END || public.rpg_map_length_text(round(p_across / q.sq)::numeric) || ' across, '
                 || 'seen from about ' || public.rpg_map_length_text(round(public.rpg_map_landmark_sight(p_height))::numeric),
         'view', o.level::text || '-' || mod(mod(floor(p_x::double precision / o.up)::bigint, o.across) + o.across, o.across)::text || '-' || floor(p_y::double precision / o.up)::bigint::text,
         'listed', false,
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
-- standing stone, a boulder and a cairn (ruins was already one).
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'town', 'city', 'great_city',
             'peak', 'castle', 'tower', 'stones', 'stone', 'rock', 'cairn'];
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
-- roll] (rpg_map_building_cells); its cost is the climb's. The kids login sees a house once a cell of it is found.
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
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif,
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
REVOKE ALL ON FUNCTION public.rpg_map_landmark_kinds() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_kinds() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_lattice() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_lattice() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_site(integer, bigint, bigint, integer, bigint, double precision, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_site(integer, bigint, bigint, integer, bigint, double precision, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_rolls(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_rolls(bigint, bigint, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_sites(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_sites(integer, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_sight(double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_sight(double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_make(integer, bigint, bigint, integer[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_make(integer, bigint, bigint, integer[], text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmarks(integer, integer, integer, integer, integer, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmarks(integer, integer, integer, integer, integer, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_entry(text, integer, text, text, text, text, bigint, bigint, double precision, double precision, integer, bigint, bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_entry(text, integer, text, text, text, text, bigint, bigint, double precision, double precision, integer, bigint, bigint, bigint, bigint) TO service_role;

-- the rule card (step 12b): landmarks
UPDATE public.rpg_rules
   SET body = replace(replace(body,
                'The map shows what your group has found:',
                'Landmarks stand out on the land and are steered by from far off: lone peaks, castles, ruins, towers, stone circles, standing stones, boulders and cairns, as big as real ones are. The World grid shows the greatest few, a great peak rising 15,000 to 20,000 feet or the ruins of a city miles across; every grid shows its own and all those of the grids above it: the Continent grid peaks and fortresses, the Country grid mountains, castles and great towers, the Region grid hills, tower houses, ruined chapels, watchtowers and stone circles, the City grid crags, mottes, ruined crofts, beacons and great standing stones, the District grid boulders, broken walls, standing stones and cairns. Peaks stand on mountains and hills, and a great peak sometimes alone on open land, as the great volcanoes do; castles on farmland and hills; ruins anywhere dry; none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own.
*A castle keep 100 feet tall is made out from about 13 miles. Its top shows over the horizon from 12.3 miles (the square root of 2 × the radius of the world × its 30.5 m), on top of the 2.7 miles of a person''s own horizon, 15 miles; but the eye makes out only what spans 5 minutes of arc, 30.5 m ÷ 0.00145 = 21 km, 13 miles, the nearer of the two. A standing stone 2 m tall is made out from about 4,500 feet, a peak rising 13,000 feet from about 140 miles.*

The map shows what your group has found:'),
                'The rest stays dark until someone goes there or knows the place.',
                'The rest stays dark until someone goes there or knows the place. A landmark shows from as far off as it can be made out, even over ground not found yet.'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('The map shows what your group has found:' IN body) > 0
   AND position('The rest stays dark until someone goes there or knows the place.' IN body) > 0
   AND position('Landmarks stand out' IN body) = 0;

