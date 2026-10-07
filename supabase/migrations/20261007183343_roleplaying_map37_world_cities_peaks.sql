-- Step 14d4 (Peter 2026-10-07 18:21/18:28, 1A: the World map's notable things are not all ruins: great cities and
-- iconic places). The World grid also shows the 5 tallest peaks of the Continent grid (4,200 m or more) and the 8 great
-- cities with the most people, kept on the World grid's saved row (rpg_map_cache.notes, a new column of the saved map,
-- filled in the background by rpg_map_cache_warm). Two new settings; no drops, no new tables.

ALTER TABLE public.rpg_map_cache ADD COLUMN IF NOT EXISTS notes jsonb;

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_world_peak_height', 4200, 'World grid (step 14d4): it also shows the Continent grid''s peaks at least this many metres tall'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_world_city_count', 8, 'World grid (step 14d4): how many of the world''s great cities it shows, those with the most people');

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
-- The World grid (step 14d, Peter 2026-10-07: only two ruins there, it should have a handful more) shows its own
-- landmarks and the Continent grid's ruined cities at least map_world_ruin_across metres across (2,200 m: 7 of the 58,
-- 2.2 to 2.9 km), the cities big enough to be marked on a map of the world, and (step 14d4, Peter 2026-10-07: great
-- cities or iconic locations, not all ruins) the Continent grid's peaks at least map_world_peak_height metres tall
-- (4,200 m: the 6 tallest of its 46); nothing else of rank 2 shows there.
WITH s AS MATERIALIZED (
       SELECT t.*, greatest(t.rank, 2) AS dl
         FROM public.rpg_map_landmark_sites(p_level, p_x0, p_y0, p_cols, p_rows) t
        CROSS JOIN (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') q
        WHERE (p_level > 1 OR t.rank = 1
               OR EXISTS (SELECT 1 FROM public.rpg_map_site_what('landmark', 2, t.rolls[1:6]) w
                           WHERE (w.kind = 'ruins'
                                  AND w.across >= (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_world_ruin_across')::double precision)
                              OR (w.kind = 'peak'
                                  AND w.height >= (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_world_peak_height')::double precision)))
          AND EXISTS (
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
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE sc.dl <> p_level AND NOT (p_level = 1 AND sc.dl = 2)) d
        CROSS JOIN LATERAL public.rpg_map_kinds(d.dl, mod(mod(d.cx, d.across) + d.across, d.across)::integer, d.cy, 1, 1) k
       UNION ALL
       -- the World grid (step 14d): the Continent cells under its sites read in one block, from the saved map
       SELECT d.dl, d.cx, d.cy, c.kind
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE p_level = 1 AND sc.dl = 2) d
         JOIN (SELECT c.* FROM public.rpg_map_ladder() l CROSS JOIN LATERAL public.rpg_map_cells(2, 0, 0, l.across::integer, l.down::integer) c
                WHERE l.level = 2 AND p_level = 1) c
           ON c.x = mod(mod(d.cx, d.across) + d.across, d.across) AND c.y = d.cy),
     -- each site with the ground it stands on
     gr AS MATERIALIZED (
       SELECT sc.*, coalesce(own.kind, far.kind) AS ground
         FROM sc
         LEFT JOIN own ON sc.dl = p_level AND own.x = sc.cx AND own.y = sc.cy
         LEFT JOIN far ON far.dl = sc.dl AND far.cx = sc.cx AND far.cy = sc.cy),
     -- what stands at each (step 14d: nothing stands on the sea, as no kind's grounds hold it, so a site there is not
     -- worked out)
     mk AS MATERIALIZED (
       SELECT gr.id, m.*
         FROM gr CROSS JOIN LATERAL public.rpg_map_landmark_make(gr.rank, gr.x, gr.y, gr.rolls, gr.ground) m
        WHERE gr.ground IS DISTINCT FROM 'sea')
SELECT gr.id, gr.rank, m.kind, m.icon, m.words, m.name, gr.x, gr.y, m.height, m.across
  FROM gr
  LEFT JOIN mk m ON m.id = gr.id
 WHERE p_level > 1 OR gr.rank = 1 OR m.kind IN ('ruins', 'peak');
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cache_warm(p_level integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Saves every grid of the World grid (1) or the Continent grid (2) not saved yet (step 14d2, 2026-10-07): the whole
-- level through rpg_map_cache_fill, the one home of saving a grid. Called in the background right after the saved map is
-- cleared (rpg_map_cache_clear), so the World map is never the one to pay for saving them: that takes about 9 seconds,
-- past the 8 a login may run a read, and the World map then failed with a timeout. Finer levels are saved as they are
-- opened, as before (one grid at a time is quick). Returns how many grids it saved; nothing for any other level.
-- (Step 14d4) The World grid's row also keeps the greatest cities of the world (notes: cities), the
-- map_world_city_count (8) great cities with the most people, read off the whole Continent grid (rpg_map_towns: about
-- 9 seconds, so only here, never while a map is opened); the World map shows them (rpg_map_view_block).
DECLARE v_n integer;
BEGIN
  IF p_level NOT IN (1, 2) THEN
    RETURN 0;
  END IF;
  v_n := (SELECT public.rpg_map_cache_fill(p_level, 0, 0, l.across::integer, l.down::integer) FROM public.rpg_map_ladder() l WHERE l.level = p_level);
  IF p_level = 1 THEN
    UPDATE public.rpg_map_cache m
       SET notes = jsonb_build_object('cities', coalesce(
             (SELECT jsonb_agg(to_jsonb(t) - 'shape' ORDER BY t.people DESC, t.id)
                FROM (SELECT t.* FROM public.rpg_map_ladder() l
                       CROSS JOIN LATERAL public.rpg_map_towns(2, 0, 0, l.across::integer, l.down::integer,
                                                               (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) FROM public.rpg_map_cells(2, 0, 0, l.across::integer, l.down::integer) c)) t
                      WHERE l.level = 2 AND t.kind = 'great_city'
                      ORDER BY t.people DESC, t.id
                      LIMIT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_world_city_count')::integer) t),
             '[]'::jsonb))
     WHERE m.level = 1 AND m.notes IS NULL;
  END IF;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view_block(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
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
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join. Under the ground (step
-- 12d2) a piece carries under = where it is in words (rpg_map_under_where); the piece whose turn it is carries ways =
-- its ways on, each [node, words] (rpg_map_under_ways, rpg_map_under_way_words; partway along a passage: on, or back),
-- mouth = it can come up here, search = it can search here for the ways up; on the surface, cave = the name of the cave
-- or mine it stands at and can go into (rpg_map_under_cave_at).
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
-- under = the world under the ground (step 12d; rpg_map_underground), from the Continent grid down to the District grid:
-- lines = its passages, each [kind (deep, cave, shaft, own, join, delve), from x, y, to x, y (thousandths of a cell from
-- the top-left corner of the block, either end may lie off it), metres down at each end, bend (hundredths of a quarter
-- of its length to one side), how wide at its middle (thousandths of a cell; step 14a), and (step 14a2) where it is
-- wide enough on the map for its bends to show, its path: points along it, each [x, y, half its width] (thousandths of
-- a cell), as rpg_map_under_trace makes them, so the map draws the passage the battle grid cuts (else null: the map
-- draws its curve), and (step 14b) its stream: [share of its width the water covers (thousandths), metres deep at
-- its middle x 10] or null (rpg_map_under_water)]; the Continent and Country grids carry the Deeps alone (step 14a2);
-- rooms (step 14a) = the room at
-- each node a passage reaches, [x, y, half-width, its eight edge knots, its lake (step 14b: [middle off the room's
-- middle across, down (thousandths of its half-width), its size as a share of the room's (thousandths), its eight edge
-- knots, metres deep x 10]) or null], as rpg_map_under_room and rpg_map_under_water make them; halls = the great halls of the Deeps in the block, each [name, x, y, metres down]. The
-- game master sees all of it; the kids login only the own passage of a cave or mine in a cell found or known.
-- On the battle grid (step 12d3) under = the battle grid under the ground instead: squares = every open square under the
-- block (rpg_map_under_squares), each [column, row (from the top-left corner of the block), part (floor, rubble, pool,
-- column, shaft), percent of time it adds (none: no way in), water metres deep, feet down], of the passages and rooms
-- of the Deeps and cave country under the block (rpg_map_underground) and of those round each piece under the ground
-- within 40 squares of it (rpg_map_under_layer: so the passage of a cave or a mine shows where a piece is in it);
-- every other square under it is solid rock. The kids login sees those the group knows, and those round its own pieces.
-- A battle grid may be read slid half a grid at a time (step 14a2; rpg_map_battle_view): view = s-<first square across>-
-- <first square down> then; slides = the grids half a grid west, east, north and south (null off the map).
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
  v_slid      boolean := false;
  v_slides    jsonb;
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
  v_caves     jsonb;
  v_under     jsonb;
  v_drivs     jsonb;
  v_rsegs     jsonb;   -- step 14c: the traced rivers' pieces near the block, for the crossings
  v_rlines    jsonb;   -- step 14c: the traced rivers' pieces drawn on the grid
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
    -- a whole grid: the world, or the grid inside one cell of the grid above; a battle grid may also be slid half a
    -- grid at a time (step 14a2, Peter 2026-10-07 3A: a passage along its edge comes into the middle), never over the
    -- east or west end of the world; v_x, v_y = the grid it is in (slid half way: the grid east or south)
    IF v_cols <> v_l.cols OR v_rows <> v_l.rows OR v_x0 < 0
       OR (v_l.level < v_last AND (mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0))
       OR (v_l.level = v_last AND (mod(v_x0, v_cols / 2) <> 0 OR mod(v_y0, v_rows / 2) <> 0 OR v_x0 + v_cols > v_l.across)) THEN
      RAISE EXCEPTION 'that grid is off the map';
    END IF;
    v_slid := mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0;
    v_x := (v_x0 + v_cols / 2) / v_cols;
    v_y := (v_y0 + v_rows / 2) / v_rows;
  END IF;
  IF p_place IS NULL AND v_l.level > 1 THEN
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the battle grid slid half a grid each way (step 14a2): a whole grid's name when it lands on one, else s-<x0>-<y0>
  -- (its first square, rpg_map_battle_view)
  IF p_place IS NULL AND v_l.level = v_last THEN
    SELECT jsonb_object_agg(d.k, CASE WHEN d.x < 0 OR d.y < 0 OR d.x + v_cols > v_l.across OR d.y + v_rows > v_l.down THEN NULL
                                      WHEN mod(d.x, v_cols) = 0 AND mod(d.y, v_rows) = 0 THEN v_l.level::text || '-' || (d.x / v_cols)::text || '-' || (d.y / v_rows)::text
                                      ELSE 's-' || d.x::text || '-' || d.y::text END)
      INTO v_slides
      FROM (VALUES ('west', v_x0 - v_cols / 2, v_y0), ('east', v_x0 + v_cols / 2, v_y0),
                   ('north', v_x0, v_y0 - v_rows / 2), ('south', v_x0, v_y0 + v_rows / 2)) AS d(k, x, y);
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
  -- the grids of the block saved the first time they are opened (step 13; rpg_map_cache_fill), so the cells are read
  -- from the saved map from then on
  PERFORM public.rpg_map_cache_fill(v_l.level, v_x0, v_y0, v_cols, v_rows);
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
       -- the rivers drawn as lines, traced (step 14c, rpg_map_river_trace), with the same margin
       rtr AS MATERIALIZED (SELECT t.x, t.y, t.k, t.seg FROM public.rpg_map_river_trace(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) t),
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
         -- the traced pieces of the rivers near the block, for the crossings (step 14c): size, ends in cells of the grid
         (SELECT jsonb_agg(jsonb_build_array(r.k, round(r.seg[1]::numeric, 4), round(r.seg[2]::numeric, 4), round(r.seg[3]::numeric, 4), round(r.seg[4]::numeric, 4)))
            FROM rtr r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4)),
         -- the rivers drawn as lines (step 14c): each piece of a traced line in a cell shown that is not water, its size
         -- and ends in thousandths of a cell from the block's first cell
         (SELECT jsonb_agg(jsonb_build_array(r.k, round((r.seg[1] - v_x0) * 1000)::integer, round((r.seg[2] - v_y0) * 1000)::integer,
                                             round((r.seg[3] - v_x0) * 1000)::integer, round((r.seg[4] - v_y0) * 1000)::integer) ORDER BY r.k, r.x, r.y, r.seg[1], r.seg[2], r.seg[3], r.seg[4])
            FROM rtr r JOIN cl ON cl.x = r.x AND cl.y = r.y
           WHERE cl.seen AND cl.kind NOT IN ('water', 'deep', 'sea')),
         -- the landmarks shown (step 12b), biggest first
         (SELECT jsonb_agg(public.rpg_map_landmark_entry(ls.id, ls.rank, ls.kind, ls.icon, ls.words, ls.name, ls.x, ls.y, ls.height, ls.across,
                                                         v_l.level, v_gx0, v_gy0, v_gx1, v_gy1) ORDER BY ls.rank, ls.name)
            FROM ls WHERE ls.shown),
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown),
         -- the caves and mines of the grid, for the world under the ground (step 12d)
         (SELECT jsonb_agg(jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near)) FROM ls WHERE ls.kind IN ('cave', 'mine'))
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_rsegs, v_rlines, v_lands, v_lmk, v_caves;

  -- the world under the ground (step 12d): its passages and its great halls
  -- (step 14a) each passage also carries how wide it runs at its middle (rpg_map_under_size, in thousandths of a cell),
  -- and rooms = the room at each node a passage reaches (rpg_map_under_room: a great hall, a chamber, the far end of a
  -- cave or a mine), each [x, y, half-width (thousandths of a cell), the eight knots of its edge (thousandths)], so the
  -- map draws tunnels and caves at their true size where that size shows
  IF v_l.level BETWEEN 2 AND 6 THEN
    WITH u AS MATERIALIZED (
           SELECT u.*, (SELECT c ->> 2 FROM jsonb_array_elements(coalesce(v_caves, '[]'::jsonb)) c
                         WHERE c ->> 0 IN (split_part(u.a, ':', 2), split_part(u.b, ':', 2)) LIMIT 1) AS skind
             FROM public.rpg_map_underground(v_l.level, v_x0, v_y0, v_cols, v_rows, v_caves, v_gm) u
            -- (step 14a2, Peter 2026-10-07 2B) the Continent and Country grids show the Deeps alone: the caves, mines and
            -- their shafts show from the Region grid down, where they can be seen
            WHERE v_l.level >= 4 OR u.kind IN ('deep', 'hall')),
         sq AS (SELECT t.sq FROM public.rpg_map_under_lattice() t),
         nd AS (SELECT DISTINCT ON (n.node) n.node, n.x, n.y, n.skind
                  FROM (SELECT u.a AS node, u.ax AS x, u.ay AS y, u.skind FROM u
                        UNION ALL SELECT u.b, u.bx, u.by, u.skind FROM u WHERE u.kind <> 'hall') n
                 WHERE n.node NOT LIKE 'mouth:%'
                 ORDER BY n.node, n.skind NULLS LAST)
    SELECT jsonb_build_object(
             'lines', coalesce((SELECT jsonb_agg(jsonb_build_array(u.kind, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell,
                                                                   (u.bx - v_gx0) * 1000 / v_l.cell, (u.by - v_gy0) * 1000 / v_l.cell,
                                                                   round(u.ad)::integer, round(u.bd)::integer, round(u.bend * 100)::integer,
                                                                   round((SELECT sqrt(z.w_low * z.w_high) FROM public.rpg_map_under_size(u.kind, u.skind,
                                                                            CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END) z)
                                                                         / sq.sq * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(jsonb_build_array(round((r.x - v_gx0) * 1000 / v_l.cell)::integer, round((r.y - v_gy0) * 1000 / v_l.cell)::integer,
                                                                                                       round(r.half * 1000 / v_l.cell)::integer) ORDER BY r.n)
                                                                      FROM public.rpg_map_under_trace(u.kind, u.a, u.b, u.ax, u.ay, u.bx, u.by, u.bend, u.skind,
                                                                                                      v_gx0, v_gy0, v_gx1, v_gy1, (v_gx1 - v_gx0) / 240.0) r),
                                                                   (SELECT jsonb_build_array(round(w.part * 1000)::integer, round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water(u.kind, u.skind, CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END,
                                                                                                      u.a || '|' || u.b) w WHERE u.kind <> 'shaft')))
                                  FROM u CROSS JOIN sq WHERE u.kind <> 'hall'), '[]'::jsonb),
             'halls', coalesce((SELECT jsonb_agg(jsonb_build_array(u.name, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell, round(u.ad)::integer)
                                               ORDER BY u.name) FROM u WHERE u.kind = 'hall'), '[]'::jsonb),
             'rooms', coalesce((SELECT jsonb_agg(jsonb_build_array((nd.x - v_gx0) * 1000 / v_l.cell, (nd.y - v_gy0) * 1000 / v_l.cell, round(r.r * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(r.knots) AS k),
                                                                   (SELECT jsonb_build_array(round(w.dx * 1000)::integer, round(w.dy * 1000)::integer, round(w.part * 1000)::integer,
                                                                                             (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(w.knots) AS k), round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water('room', nd.skind, nd.node, nd.node) w)) ORDER BY nd.node)
                                  FROM nd CROSS JOIN LATERAL public.rpg_map_under_room(nd.node, nd.skind) r), '[]'::jsonb))
      INTO v_under;
  END IF;

  -- the battle grid under the ground (step 12d3)
  IF v_l.level = 7 THEN
    SELECT jsonb_build_object('lines', '[]'::jsonb, 'halls', '[]'::jsonb,
             'squares', coalesce(jsonb_agg(jsonb_build_array(q.x - v_x0, q.y - v_y0, q.part, q.pct, q.water, round(q.down / 0.3048)::integer) ORDER BY q.y, q.x), '[]'::jsonb))
      INTO v_under
      FROM public.rpg_map_under_squares(v_x0, v_y0, v_cols, v_rows, (
             SELECT coalesce(jsonb_agg(w.j), '[]'::jsonb) FROM (
               SELECT jsonb_build_object('kind', u.kind, 'a', u.a, 'b', u.b, 'ax', u.ax, 'ay', u.ay, 'bx', u.bx, 'by', u.by, 'ad', u.ad, 'bd', u.bd, 'bend', u.bend) AS j
                 FROM public.rpg_map_underground(7, v_x0, v_y0, v_cols, v_rows, NULL, v_gm) u
               UNION ALL
               SELECT l.j
                 FROM public.rpg_session_participants p
                 JOIN public.rpg_sessions s ON s.id = p.session_id AND s.on_map AND s.status <> 'ended'
                CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_under_layer(p.under_at, p.under_to)) AS l(j)
                WHERE p.under_at IS NOT NULL AND (v_gm OR p.creature_id IS NULL)
                  AND p.pos_x - 1 BETWEEN v_x0 - 40 AND v_x0 + v_cols + 40 AND p.pos_y - 1 BETWEEN v_y0 - 40 AND v_y0 + v_rows + 40) w)) q;
  END IF;

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
    -- the grids the fine drawing reads, saved the first time (step 13): the World grid draws every Continent grid
    PERFORM public.rpg_map_cache_fill(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr);
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
            WHERE v_l.level + 1 = 4 AND t.kind IS NOT NULL
           UNION ALL
           -- the World grid (step 14d4): the greatest cities of the world, kept on its saved row (rpg_map_cache_warm)
           SELECT t.id, t.kind, t.name, t.people, t.x, t.y, t.r, NULL::double precision[]
             FROM public.rpg_map_cache m
            CROSS JOIN LATERAL jsonb_to_recordset(m.notes -> 'cities') AS t(id text, kind text, name text, people integer, x bigint, y bigint, r double precision)
            WHERE v_l.level = 1 AND m.level = 1 AND m.gx = 0 AND m.gy = 0),
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
         -- (step 14c) a river traced as a line crosses a road where a piece of the road meets a piece of the river; the
         -- straight-in-a-cell rule below is kept for rivers that are water on this grid (as wide as its cells), and for a
         -- view drawn from its detail (the world, a place shown whole), whose rivers are not traced
         rvw AS MATERIALIZED (SELECT rv.* FROM rv WHERE rv.width >= 1 OR v_detail IS NOT NULL),
         rs AS MATERIALIZED (
           SELECT (e.v ->> 0)::integer AS k, (e.v ->> 1)::double precision - g.x0 AS x1, (e.v ->> 2)::double precision - g.y0 AS y1,
                  (e.v ->> 3)::double precision - g.x0 AS x2, (e.v ->> 4)::double precision - g.y0 AS y2,
                  floor(((e.v ->> 1)::double precision + (e.v ->> 3)::double precision) / 2 - g.x0)::integer AS cu,
                  floor(((e.v ->> 2)::double precision + (e.v ->> 4)::double precision) / 2 - g.y0)::integer AS cv,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || (e.v ->> 0) || '_width')::double precision / g.cell AS width
             FROM g CROSS JOIN jsonb_array_elements(coalesce(CASE WHEN v_detail IS NULL THEN v_rsegs END, '[]'::jsonb)) AS e(v)
            WHERE g.level BETWEEN 4 AND 6),
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rvw WHERE rvw.x = g.x0 + floor(q.ox)::integer AND rvw.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rvw r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rvw)),
         -- the cells each piece of road spans (and a quarter cell round it, where a river piece's middle may lie), to meet the river pieces of those cells
         lc AS (SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, cu, cv
                  FROM ls
                 CROSS JOIN LATERAL generate_series(floor(least(ls.u, ls.nu) - 0.25)::integer, floor(greatest(ls.u, ls.nu) + 0.25)::integer) AS cu
                 CROSS JOIN LATERAL generate_series(floor(least(ls.v, ls.nv) - 0.25)::integer, floor(greatest(ls.v, ls.nv) + 0.25)::integer) AS cv
                 WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rs)),
         xt AS (
           SELECT DISTINCT lc.n, lc.class, lc.a, lc.b, lc.u, lc.v, lc.nu, lc.nv, rs.k, rs.width,
                  lc.u + t.t * (lc.nu - lc.u) AS xu, lc.v + t.t * (lc.nv - lc.v) AS xv
             FROM lc
             JOIN rs ON rs.cu = lc.cu AND rs.cv = lc.cv
            CROSS JOIN LATERAL (SELECT (lc.nu - lc.u) * (rs.y2 - rs.y1) - (lc.nv - lc.v) * (rs.x2 - rs.x1) AS dd) q
            CROSS JOIN LATERAL (SELECT ((rs.x1 - lc.u) * (rs.y2 - rs.y1) - (rs.y1 - lc.v) * (rs.x2 - rs.x1)) / q.dd AS t,
                                       ((rs.x1 - lc.u) * (lc.nv - lc.v) - (rs.y1 - lc.v) * (lc.nu - lc.u)) / q.dd AS s) t
            WHERE q.dd <> 0 AND t.t >= 0 AND t.t < 1 AND t.s >= 0 AND t.s < 1),
         xs AS (
           SELECT cx.class, cx.k, cx.a, cx.b, cx.u, cx.v, cx.nu, cx.nv, cx.width, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1
           UNION ALL
           SELECT xt.class, xt.k, xt.a, xt.b, xt.u, xt.v, xt.nu, xt.nv, xt.width, xt.xu, xt.xv FROM xt),
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
                      -- under the ground (step 12d2)
                      'under', CASE WHEN p.under_at IS NOT NULL THEN public.rpg_map_under_where(p.under_at, p.under_to, p.under_done) END,
                      'ways', CASE WHEN p.under_at IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN CASE WHEN p.under_to IS NULL
                                             THEN (SELECT jsonb_agg(jsonb_build_array(w.to_node,
                                                                      public.rpg_map_under_way_words(w.kind, w.skind, w.up, w.metres,
                                                                                                     public.rpg_ticks_at(public.rpg_participant_speed(p.id), w.base),
                                                                                                     w.to_name, w.to_depth, w.to_sea))
                                                                    ORDER BY w.metres)
                                                     FROM public.rpg_map_under_ways(p.under_at, false, NULL) w)
                                             ELSE jsonb_build_array(jsonb_build_array(p.under_to, 'Go on to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_to) n)),
                                                                    jsonb_build_array(p.under_at, 'Go back to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_at) n))) END END,
                      'mouth', CASE WHEN p.under_at LIKE 'mouth:%' AND p.under_to IS NULL THEN true END,
                      'search', CASE WHEN p.under_to IS NULL AND (p.under_at LIKE 'deep-%' OR p.under_at LIKE 'cave-%') THEN true END,
                      'cave', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN (SELECT c.name FROM public.rpg_map_under_cave_at(p.pos_x, p.pos_y) c) END,
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
                 WHEN v_slid THEN 's-' || v_x0::text || '-' || v_y0::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves, 'slides', v_slides,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'roads', coalesce(v_roads, '[]'::jsonb), 'road_width', v_rw,
    'crossings', coalesce(v_cross, '[]'::jsonb),
    -- the rivers drawn as lines on the grid (step 14c): [size, x1, y1, x2, y2] in thousandths of a cell from the first cell
    'river_lines', v_rlines,
    'houses', coalesce(v_houses, '[]'::jsonb),
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'under', v_under,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

