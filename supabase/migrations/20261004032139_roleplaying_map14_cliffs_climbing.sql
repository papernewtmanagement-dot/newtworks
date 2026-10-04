-- Step 7c (Peter 2026-10-03 23:07, 23:12; 2026-10-04 03:08 "Go"): steep ground and climbing. Some mountain rock is
-- too steep to walk and has to be climbed: a Climbing roll against how steep it is, climbing gear adding to the
-- climber's own roll through Climbing with Gear, a skill built on Climbing. Buildings join when towns come (step 8).

-- Real numbers. A rubber sole grips dry rock with friction about 0.8, so feet alone hold up to atan 0.8 = 39 degrees,
-- and loose rock will not rest steeper than about 35 degrees (its angle of repose): ground steeper than 40 degrees is
-- bare rock that takes hands. How hard a pitch is follows the share of the body's weight the hands must hold,
-- sin(angle) - 0.8 x cos(angle): none at 39 degrees, half at 62, all of it at 90; half the weight on the hands is the
-- standard challenge, difficulty 5. Climbing goes about 300 m up an hour, half the 600 m an hour of a walker's climb in
-- Naismith's rule. A fall of 15 m leaves someone down (falls from about four storeys kill about half the people who
-- take them) while short falls rarely do real harm, so a fall costs (height / 15 m) squared of a person's vitality. How many mountain squares are cliffs is the one game choice here: one in
-- twenty, in patches from about a hundred metres across down to a single square, 40 to 85 degrees steep, the steep
-- ones rare. A walk longer than 72 squares reads the map in coarser runs and picks its way round them (the mountain's
-- own time allows for that); a shorter one, and every move on a fight board, crosses the battle grid square by square
-- and climbs.
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_cliff_share', 0.05::numeric, 'Cliffs: share of mountain squares too steep to walk (a game choice; in patches)'),
               ('map_cliff_from', 6, 'Cliffs: the grid whose first layer of rolls starts the cliff patches (6, the District grid: about 100 m apart)'),
               ('map_cliff_angle_low', 40, 'Cliffs: the least steep, degrees (steeper than a sole grips dry rock and than loose rock rests)'),
               ('map_cliff_angle_high', 85, 'Cliffs: the steepest, degrees'),
               ('map_foot_grip', 0.8, 'Friction of a rubber sole on dry rock (feet alone hold up to atan 0.8 = 39 degrees)'),
               ('map_climb_even_load', 0.5, 'Climbing: the share of body weight on the hands that is difficulty 5 (half, at about 62 degrees)'),
               ('map_climb_rate', 300, 'Climbing: metres climbed in an hour (half the 600 m an hour of a walker''s climb in Naismith''s rule)'),
               ('climb_fall_down_m', 15, 'Climbing: a fall this many metres leaves someone down; a shorter fall costs (height / this) squared of their vitality')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_steep(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, steep double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How steep each cell of a block could be, 0 to 1, worked out when asked and never stored: the one home of where cliffs
-- stand (step 7c). It is the layered rolls of part 10 (rpg_map_rolls) from the first layer of the grid map_cliff_from
-- (6, the District grid: points about 100 m apart) down to one square, turned into a share spread evenly from 0 to 1 by
-- the normal curve, the same way as rpg_map_hard (steep = (1 + erf(roll / (spread x sqrt 2))) / 2, the spread from how
-- the rolls are made: 34.3 for the six layers from the District grid down). A mountain square whose steep is in the top
-- map_cliff_share (1 in 20) is a cliff (rpg_map_cliff_angle). Cliffs stand only on the battle grid: a coarser grid's
-- cells are walked at their ground's own time, which allows for picking a way round them.
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cliff_from')::integer AS cfrom,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers),
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0)
                        * sum(CASE WHEN q.r <= cfg.full_layers THEN 1 ELSE power(cfg.share, 2 * (q.r - cfg.full_layers)) END)) AS s
              FROM cfg
             CROSS JOIN LATERAL (SELECT row_number() OVER (ORDER BY y.n) AS r FROM public.rpg_map_layers() y WHERE y.n >= 3 * cfg.cfrom - 2) q
             GROUP BY cfg.cfrom)
SELECT r.x, r.y, 0.5 * (1 + erf(r.value / (sd.s * sqrt(2::double precision))))
  FROM cfg CROSS JOIN sd
 CROSS JOIN LATERAL public.rpg_map_rolls(10, 3 * cfg.cfrom - 2, 1, p_level, p_x0, p_y0, p_cols, p_rows) r
 WHERE p_level = 7;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cliff_angle(p_steep double precision)
 RETURNS double precision
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How steep a mountain square is, in degrees, when it is a cliff: its steep (rpg_map_steep) in the top map_cliff_share
-- (1 in 20), from map_cliff_angle_low (40) to map_cliff_angle_high (85), with the steepest the rarest the way slopes
-- thin out past 40 degrees in real mountains: angle = 40 + 45 x t squared, t = how far up the top 1 in 20 it is. Half
-- the cliffs are under 51 degrees, 1 in 10 over 76. Nothing when it is not a cliff (the mountain is walked, at its own
-- percent). Steep 0.975 is halfway up the top 1 in 20: 51.3 degrees.
SELECT CASE WHEN p_steep IS NULL OR p_steep < 1 - c.share THEN NULL
            ELSE c.low + (c.high - c.low) * power(least((p_steep - (1 - c.share)) / c.share, 1), 2) END
  FROM (SELECT public.rpg_setting('map_cliff_share')::double precision AS share,
               public.rpg_setting('map_cliff_angle_low')::double precision AS low,
               public.rpg_setting('map_cliff_angle_high')::double precision AS high) c;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climb(p_angle double precision)
 RETURNS TABLE(rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it takes to climb a square of rock p_angle degrees steep: the one home of those sums (step 7c).
-- rise = how many metres the square climbs (a square, map_square_m 1.118 m, x tan angle).
-- difficulty = default_difficulty (5) x the share of the body's weight the hands hold / map_climb_even_load (0.5):
--   that share is sin(angle) - map_foot_grip (0.8) x cos(angle), so 40 degrees is 0.3, 62 degrees 5, 85 degrees 9.3.
-- pct = the percent of time it adds to the square's 5 ticks: the rise at map_climb_rate (300 m an hour), ticks_per_hour
--   to the hour. 60 degrees: 1.94 m, 139 ticks, +2,688%.
SELECT r.rise,
       round((public.rpg_setting('default_difficulty') * greatest(sin(radians(p_angle)) - public.rpg_setting('map_foot_grip')::double precision * cos(radians(p_angle)), 0)
              / public.rpg_setting('map_climb_even_load')::double precision)::numeric, 1),
       round((r.rise / public.rpg_setting('map_climb_rate')::double precision * public.rpg_setting('ticks_per_hour')::double precision
              / public.rpg_setting('move_ticks')::double precision - 1) * 100)::integer
  FROM (SELECT public.rpg_setting('map_square_m')::double precision * tan(radians(p_angle)) AS rise) r
 WHERE p_angle IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cliff(p_x integer, p_y integer)
 RETURNS TABLE(angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cliff a world square holds (p_x, p_y counted from 1, as pieces stand): how steep it is, how high it climbs, the
-- difficulty of the Climbing roll and the percent of time it adds (rpg_map_climb). No row when the square is not a
-- mountain cliff (rpg_map_cells on the battle grid, rpg_map_steep, rpg_map_cliff_angle).
SELECT a.angle, m.rise, m.difficulty, m.pct
  FROM public.rpg_map_ladder() l
 CROSS JOIN LATERAL (SELECT mod(p_x - 1 + l.span, l.span) AS x, p_y - 1 AS y) q
 CROSS JOIN LATERAL public.rpg_map_cells(7, q.x, q.y, 1, 1) c
 CROSS JOIN LATERAL public.rpg_map_steep(7, q.x, q.y, 1, 1) s
 CROSS JOIN LATERAL (SELECT public.rpg_map_cliff_angle(s.steep) AS angle) a
 CROSS JOIN LATERAL public.rpg_map_climb(a.angle) m
 WHERE l.level = 1 AND c.kind = 'mountains' AND a.angle IS NOT NULL;
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
-- water too rough to swim. On the battle grid a mountain square that is a cliff (rpg_map_steep, rpg_map_cliff_angle;
-- step 7c) is climbed: its percent is the climb's (rpg_map_climb: 60 degrees +2,688%) and its hard is 1, the darkest.
-- The one way a block of the map is read with its costs: fight boards (rpg_fight_squares) and the Maps tab
-- (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the water's depth and pull only when the block holds water shallow enough to wade, or deep water on the battle
     -- grid (deep water is shaded full; on a coarser grid it is the average swim)
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth, w.current FROM public.rpg_map_flow(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind = 'water' OR (p_level = 7 AND c.kind = 'deep'))),
     -- cliffs: on the battle grid, only when the block holds mountains
     cl AS MATERIALIZED (SELECT t.x, t.y, m.pct
                           FROM public.rpg_map_steep(p_level, p_x0, p_y0, p_cols, p_rows) t
                          CROSS JOIN LATERAL public.rpg_map_climb(public.rpg_map_cliff_angle(t.steep)) m
                          WHERE p_level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'mountains')),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            WHEN c.kind = 'deep' THEN CASE WHEN wt.x IS NOT NULL AND public.rpg_map_swim_difficulty(wt.current) IS NULL THEN NULL
                                           ELSE public.rpg_map_wade_pct(coalesce(wt.depth, sw.swim)) END
            WHEN c.kind = 'mountains' AND cl.x IS NOT NULL THEN cl.pct
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1)
            WHEN c.kind = 'mountains' AND cl.x IS NOT NULL THEN 1 ELSE h.hard END
  FROM c
 CROSS JOIN sw
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN cl ON cl.x = c.x AND cl.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
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
           -- the battle grid's mountains and hills: how near the square is to the middle line of its chain, in
           -- thousandths of a ground roll below it (0 on the line; rpg_map_blend part 1, the roll that makes them), so
           -- the page can tell which way is uphill and draw the slope (Peter 2026-10-04: a mountain side)
           'rise', CASE WHEN k.seen AND c.kind IN ('mountains', 'hills') AND bl.value IS NOT NULL THEN round(-abs(bl.value) * 1000)::integer END,
           -- the battle grid's cliffs: how steep, in degrees (rpg_map_cliff_angle; step 7c), so the page draws the rock face
           'cliff', CASE WHEN k.seen AND c.kind = 'mountains' THEN round(public.rpg_map_cliff_angle(st.steep))::integer END,
           'river', CASE WHEN k.seen AND rv.line > 0 AND c.kind NOT IN ('water', 'deep', 'sea')
                         THEN jsonb_build_array(rv.line, round(rv.px * 1000)::integer, round(rv.py * 1000)::integer) END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || wx.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(wx.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows) c
    LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level, v_x0, v_y0, v_cols, v_rows) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
    LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
    LEFT JOIN public.rpg_map_steep(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
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
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM public.rpg_map_costs(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id))
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


CREATE OR REPLACE FUNCTION public.rpg_climb_check(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The climb when someone moves onto a cliff square on the board (Peter 2026-10-03 23:12: how steep it is sets the
-- challenge; climbing gear adds to the climber's own roll; Climbing with Gear is built on Climbing). Called by
-- rpg_act_square before the piece moves; nothing happens off a cliff (no row: the move goes ahead as it is).
-- The roll: Climbing against the cliff's difficulty (rpg_map_cliff: 60 degrees 4.7). With climbing gear (an item worn
-- or held that adds to Climbing with Gear) they roll Climbing with Gear instead, gear and all. Someone with no open
-- Climbing climbs as skill 0: only a 100 gets them up. A creature's roll is made from its sheet without training it; a
-- character's goes through rpg_roll (it trains).
-- Made it: they climb onto the square. Missed: they slip and fall back to where they started, the height of the square
-- (1.94 m at 60 degrees), and lose (height / climb_fall_down_m, 15 m) squared of their Physical Vitality, at least 1:
-- Karen (41) falling 1.94 m loses 1, falling 6.3 m (80 degrees) loses 8. At 0 they are down. The time of the climb is
-- spent either way.
-- Returns {made, text}, or nothing when the square is not a cliff.
DECLARE
  v_p record; v_s record; v_c record; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer; v_made boolean;
  v_text text; v_gear boolean; v_harm integer := 0; v_roll_id uuid; v_out text; v_max integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) THEN RETURN NULL; END IF;
  SELECT * INTO v_c FROM public.rpg_map_cliff(p_x, p_y);
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
            AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
  v_key := CASE WHEN v_gear THEN 'climb_gear' ELSE 'CL' END;
  v_skill := public.rpg_participant_value(p_participant_id, v_key);
  PERFORM set_config('rpg.engine', 'on', true);
  IF v_p.creature_id IS NULL AND v_skill IS NOT NULL THEN
    v_r := public.rpg_roll(v_p.character_id, v_key, v_c.difficulty, 'Climbing a cliff', NULL, v_s.id, p_participant_id);
    v_roll := (v_r->>'roll')::integer; v_nc := jsonb_build_object('needed', v_r->'needed', 'critical', v_r->'critical'); v_roll_id := (v_r->>'roll_id')::uuid;
  ELSE
    v_nc := public.rpg_needed(coalesce(v_skill, 0), v_c.difficulty);
    v_roll := floor(random() * 100)::integer + 1;
  END IF;
  v_made := v_roll >= (v_nc->>'needed')::numeric;
  v_out := public.rpg_outcome(v_roll, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, false, 0)->>'key';
  v_text := v_p.name || ' climbs a ' || round(v_c.angle) || '-degree cliff, ' || trim_scale(round(v_c.rise::numeric, 1)) || ' m ('
         || CASE WHEN v_gear THEN 'Climbing with Gear ' ELSE 'Climbing ' END || trim_scale(coalesce(v_skill, 0)) || ' against ' || trim_scale(v_c.difficulty)
         || '): rolls ' || v_roll || ', needs ' || ceil((v_nc->>'needed')::numeric) || '. ';
  IF v_made THEN
    v_text := v_text || 'Makes it up.';
  ELSE
    v_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
    v_harm := greatest(ceil(v_max * power(v_c.rise / public.rpg_setting('climb_fall_down_m')::double precision, 2))::integer, 1);
    PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_harm);
    v_text := v_text || 'Slips and falls ' || trim_scale(round(v_c.rise::numeric, 1)) || ' m: ' || v_harm || ' damage'
           || CASE WHEN (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN '. Down.' ELSE '.' END;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out, p_participant_id, v_roll_id, v_text);
  RETURN jsonb_build_object('made', v_made, 'harm', v_harm, 'text', v_text);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_square(p_actor_id uuid, p_x integer, p_y integer, p_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A move on the board, which is the world map under the fight (squares counted from 1, as pieces stand; a fight off
-- the map has no board). Moving onto a cliff square takes a Climbing roll first (rpg_climb_check; step 7c): a miss is a
-- fall back where they stood, the time spent all the same. With no action it is a walk by the one whose turn it is: the path cost (rpg_grid_costs) × 
-- move_ticks at their Speed goes on the turn's moving time, and a turn holds round_ticks (20) of it (Zaboo, Speed 5,
-- walks 2 plain squares in 13 ticks; Karen, Speed 1, in 18). With a card action that works on a square: a step
-- (Rootstep: up to rpg_step_budget of path, 200, two plain squares, as a legendary action on someone else's turn,
-- using no time) or a board action (Briar Shift: every square within 1 of a square in its reach takes 200 more percent
-- of time to cross, up to 900). A walk takes what rpg_grid_costs allows: within the turn's moving, or any one square as
-- the first step of the turn, which may make the turn longer.
-- A thing held in the hand lends its card's square actions (a Torch: Light the ground sets a square alight for
-- burn_rounds rounds as the turn's action, rpg_ignite; on forest ground that is a tree harmed, rpg_judgement); one
-- use of the thing is spent when it counts uses. Players move their own characters; the game master moves creatures.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_akind text; v_aname text; v_on text;
  v_cost integer; v_ticks integer; v_budget integer;
  v_text text; v_sq text := public.rpg_square_name(p_x, p_y);
  v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer; v_item record; v_forest boolean; v_pen integer; v_climb jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
     OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  IF v_actor.creature_id IS NOT NULL AND NOT v_gm THEN RAISE EXCEPTION 'the game master moves %', v_actor.name; END IF;
  IF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;
    IF v_act.creature_id IS DISTINCT FROM v_actor.creature_id THEN
      -- the action comes from a thing held in the hand: the first unbroken one of that card
      SELECT i.id, i.name, i.uses_left INTO v_item FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
       WHERE i.character_id = v_actor.character_id AND i.equipped AND NOT i.worn AND o.template_id = v_act.creature_id
         AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean
       ORDER BY i.sort_order LIMIT 1;
      IF v_item.id IS NULL THEN RAISE EXCEPTION '% is not holding anything that can %', v_actor.name, v_act.name; END IF;
    END IF;
    v_akind := v_act.kind; v_aname := v_act.name; v_on := v_act.effect->>'on';
    IF v_on IS DISTINCT FROM 'step' AND v_on IS DISTINCT FROM 'board' THEN RAISE EXCEPTION '% is not aimed at a square', v_aname; END IF;
    IF v_akind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_akind IN ('action', 'bonus_action') AND v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
    IF v_akind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_aname, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      v_energy := public.rpg_participant_energy(p_actor_id);
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_aname, v_act.energy_cost;
    END IF;
  END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_actor_id AND NOT (v_gm AND v_akind IS NOT DISTINCT FROM 'legendary') THEN
    RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
  END IF;
  IF NOT public.rpg_participant_can_act(p_actor_id) THEN RAISE EXCEPTION '% cannot move right now', v_actor.name; END IF;

  IF v_on IS NULL OR v_on = 'step' THEN
    IF v_actor.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the board yet; the game master places them first', v_actor.name; END IF;
    IF v_actor.pos_x = p_x AND v_actor.pos_y = p_y THEN RAISE EXCEPTION '% is already on %', v_actor.name, v_sq; END IF;
    IF v_on IS NULL THEN
      v_budget := public.rpg_move_budget(p_actor_id, v_s.turn_move_ticks);
    ELSE
      v_budget := public.rpg_step_budget(coalesce((v_act.effect->>'beats')::integer, 1));
    END IF;
    SELECT g.cost INTO v_cost FROM public.rpg_grid_costs(p_actor_id, v_budget) g WHERE g.x = p_x AND g.y = p_y;
    IF v_cost IS NULL THEN RAISE EXCEPTION '% cannot get to % this turn: too far, the sea, or someone in the way', v_actor.name, v_sq; END IF;
    IF v_on IS NULL THEN
      v_ticks := public.rpg_ticks_at(public.rpg_participant_speed(p_actor_id), v_cost * public.rpg_setting('move_ticks') / 100);
      UPDATE public.rpg_sessions SET turn_move_ticks = turn_move_ticks + v_ticks, updated_at = now() WHERE id = v_s.id;
      v_text := v_actor.name || ' moves to ' || v_sq || ' (' || v_ticks || ' ticks).';
    ELSE
      v_budget := public.rpg_step_budget(coalesce((v_act.effect->>'beats')::integer, 1));
      IF v_cost > v_budget THEN
        RAISE EXCEPTION '% goes as far as % plain squares with %, and % takes the time of % to reach', v_actor.name, trim_scale(round(v_budget / 100.0, 2)), v_aname, v_sq, trim_scale(round(v_cost / 100.0, 2));
      END IF;
      v_text := v_actor.name || ' uses ' || v_aname || ' and moves to ' || v_sq || '.';
    END IF;
    v_climb := public.rpg_climb_check(p_actor_id, p_x, p_y);
    IF v_climb IS NULL OR (v_climb->>'made')::boolean THEN
      UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y WHERE id = p_actor_id;
    ELSE
      v_text := replace(v_text, ' moves to ', ' tries to climb to ') || ' Falls back.';
    END IF;
  ELSE
    IF v_actor.pos_x IS NOT NULL THEN
      v_dist := public.rpg_square_gap(v_actor.pos_x, v_actor.pos_y, p_x, p_y);
      IF v_dist > v_act.reach THEN RAISE EXCEPTION '% is % squares away and % reaches %', v_sq, v_dist, v_aname, v_act.reach; END IF;
    END IF;
    IF coalesce((v_act.effect->>'burn')::boolean, false) THEN
      -- fire: the square burns for burn_rounds (rpg_ignite); forest ground set alight is a tree harmed (rpg_judgement)
      SELECT f.forest INTO v_forest FROM public.rpg_fight_square(v_s.id, p_x, p_y) f;
      v_text := v_actor.name || ' lights ' || v_sq || ' with ' || coalesce(v_item.name, v_aname) || '.' || public.rpg_ignite(v_s.id, p_x, p_y);
      IF v_forest THEN v_text := v_text || coalesce(public.rpg_judgement(p_actor_id, NULL, true), ''); END IF;
    ELSE
      v_raise := coalesce((v_act.effect->>'raise')::integer, 100);
      v_r := coalesce((v_act.effect->>'radius')::integer, 0);
      FOR v_x IN greatest(p_x - v_r, 1) .. p_x + v_r LOOP
        FOR v_y IN greatest(p_y - v_r, 1) .. p_y + v_r LOOP
          SELECT f.penalty INTO v_pen FROM public.rpg_fight_square(v_s.id, v_x, v_y) f;
          CONTINUE WHEN v_pen IS NULL;
          PERFORM public.rpg_square_set(v_s.id, v_x, v_y, least(v_pen + v_raise, 900));
        END LOOP;
      END LOOP;
      v_text := v_actor.name || ' uses ' || v_aname || ': the ground around ' || v_sq || ' gets harder to cross (+' || v_raise || '% time a square).';
    END IF;
  END IF;

  IF p_action_id IS NOT NULL THEN
    IF v_akind IN ('action', 'bonus_action') AND coalesce(v_act.beats, 0) > 0 THEN
      UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_act.beats) WHERE id = v_s.id;
    END IF;
    IF v_item.id IS NOT NULL AND v_item.uses_left IS NOT NULL THEN PERFORM public.rpg_item_use(v_item.id); END IF;
    IF v_act.energy_cost > 0 THEN
      IF v_act.energy_type = 'spiritual' THEN
        UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_act.energy_cost WHERE id = p_actor_id;
      ELSE
        UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_act.energy_cost WHERE id = p_actor_id;
      END IF;
    END IF;
    IF v_akind = 'lair' THEN UPDATE public.rpg_session_participants SET lair_round = v_s.round WHERE id = p_actor_id; END IF;
    IF v_akind = 'legendary' THEN
      UPDATE public.rpg_session_participants SET legendary_left = legendary_left - v_act.legendary_cost WHERE id = p_actor_id;
    END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
  RETURN jsonb_build_object('kind', 'move', 'label', coalesce(v_aname, 'Move'),
                            'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
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
--   a mountain cliff is climbed (step 7c): on the battle grid each cliff square (rpg_map_steep, rpg_map_cliff_angle)
--   takes its climb's time (rpg_map_climb) and a Climbing roll (Climbing with Gear with climbing gear on) against its
--   difficulty (a walk read in coarser runs, longer than 72 squares, picks its way round cliffs: the mountain's own time
--   allows for that). A miss is a fall the height of the square ((height / climb_fall_down_m, 15 m) squared of their vitality) and the climb again; if
--   they go down the walk stops at the foot of that cliff. Climbing trains like swimming;
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
  v_cliff double precision; v_cl_rise double precision; v_cl_dif numeric; v_cl_key text; v_cl_skill numeric; v_cl_gear boolean;
  v_cl_rolls integer := 0; v_cl_points numeric := 0; v_cl_falls integer := 0; v_cl_harm integer := 0; v_cl_count integer := 0; v_cl_maxdif numeric := 0;
  v_cl_n integer; v_cl_extra numeric; v_cl_try bigint; v_cl_left integer; v_cl_max integer; v_fixed bigint := 0; j integer;
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
      -- a cliff on the battle grid: climbed, at its climb's time
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_r.kind = 'mountains' AND v_r.level = 7 THEN
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
  v_walk := public.rpg_ticks_at(v_speed, (v_base + v_fixed) / 100.0);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') NOT IN ('drown', 'fell') AND v_p.day_walk_ticks + v_walk >= v_day);
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
         || CASE WHEN v_cl_count > 0 THEN ' Climbs ' || v_cl_count || CASE WHEN v_cl_count = 1 THEN ' cliff: ' ELSE ' cliffs: ' END || v_cl_rolls || CASE WHEN v_cl_rolls = 1 THEN ' Climbing roll' ELSE ' Climbing rolls' END
                                          || CASE WHEN v_cl_gear THEN ' with gear' ELSE '' END || ' (' || trim_scale(coalesce(v_cl_skill, 0)) || ' against up to ' || trim_scale(v_cl_maxdif) || ')'
                                          || CASE WHEN v_cl_falls > 0 THEN ', ' || v_cl_falls || CASE WHEN v_cl_falls = 1 THEN ' fall' ELSE ' falls' END || ': ' || v_cl_harm || ' damage' ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_why = 'fell' THEN ' Falls and is down at the foot of a cliff.' ELSE '' END
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


-- Climbing with Gear (Peter 2026-10-03 23:12): a skill built on Climbing; gear adds to it (an item's bonus).
INSERT INTO public.rpg_stat_definitions (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, reach, spirit_discipline, template_id)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'climb_gear', 'Climbing with Gear', 'CLG', 'ability', 'derived', true, '{"div": 1, "parts": [["CL", 1]]}'::jsonb, 0, 391, false, 2, 4, 'physical', 1, false, '58b4e57e-db74-428a-9883-a3acc029d1ac'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'climb_gear');

INSERT INTO public.rpg_rules (agency_id, key, title, body, source, sort_order, section)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'climbing', 'Climbing', $card$Bare rock steeper than 40 degrees cannot be walked: a rubber sole grips dry rock only up to about 39 degrees, and loose stones will not rest steeper than about 35. It has to be climbed, hands and all. One mountain square in twenty is a cliff like that, in patches, from 40 to 85 degrees steep, the steep ones rare: half are under 51 degrees, 1 in 10 over 76. The battle grid draws its rock face. Buildings will be climbed the same way once towns come.

Climbing is slow: about 300 m up an hour, half a walker's pace up a hill. A cliff square climbs 1.118 m times how steep it is (its tangent), and takes that long.
*A 60-degree cliff square climbs 1.94 m: 139 ticks at Speed 10, +2,688% time. Karen (Speed 1) takes 253 ticks, 42 seconds.*

Moving onto a cliff square takes a Climbing roll against the cliff. How hard it is follows how much of your weight your hands must hold: none at 39 degrees, half at 62 degrees (difficulty 5), nearly all near vertical. Difficulty = 5 × (sin of the angle − 0.8 × cos of the angle) ÷ 0.5.
*40 degrees is difficulty 0.3, 60 degrees 4.7, 85 degrees 9.3. Karen (Climbing 7) on a 60-degree cliff needs 100 × 4.7 ÷ (4.7 + 7) = 41 or more.*

Make it and you are up. Miss it and you slip and fall the height of the square, back where you started, and the time is spent all the same. A fall of 15 m leaves you down. Short falls rarely do real harm, so a fall takes (its height ÷ 15 m) squared of your Physical Vitality, at least 1.
*Karen (Physical Vitality 41) falls 1.94 m: 41 × (1.94 ÷ 15)² = 0.7, so 1 damage. From an 80-degree square, 6.3 m: 41 × (6.3 ÷ 15)² = 7.3, so 8.*

On a fight board a cliff square is so slow that it is always the first and only step of a turn, and the turn takes that long. On a journey, a walk of up to 72 squares (80 m) goes square by square and the site climbs every cliff on its line for you: a miss is a fall and a climb again, and if you go down the walk stops at the foot of that cliff. A longer walk picks its way round the cliffs; the mountains' own +200% to +500% allows for that. Every roll trains Climbing like any roll.

Climbing gear (rope, holds, harness) adds to the climber's own roll. With gear worn or held, the roll is Climbing with Gear, a skill built on Climbing (it starts at your Climbing and trains on its own), plus what the gear adds.
*A rope and harness that add 3 to Climbing with Gear make Karen's roll 7 + 3 = 10.*$card$, 'peter', 49, 'Fights'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules r WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND r.key = 'climbing');
UPDATE public.rpg_rules SET body = replace(body,
'mountains +200% to +500%. Water goes by its depth',
'mountains +200% to +500%, and one mountain square in twenty is a cliff that has to be climbed, a Climbing roll and far more time (see Climbing). Water goes by its depth'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('one mountain square in twenty' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, +25% to +75%.',
'Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, +25% to +75%. One mountain square in twenty is a cliff, climbed with a Climbing roll (see Climbing).'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('one mountain square in twenty' IN lower(body)) = 0;

