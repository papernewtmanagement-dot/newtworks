-- Roleplaying world map, corrections step 4 (Peter 2026-10-03): a named land opens whole. Westerwold is a massive
-- continent, and opening it showed one Continent grid, a part of it. A place now opens on the block of cells that
-- holds all of it (rpg_map_place_block): the cells the box round its oval reaches into, on the finest grid above its
-- own kind where they fit in one grid's worth of cells, drawn one level finer the way the world is. Westerwold opens
-- on 5 by 6 cells of the world grid, Havenmark on 5 by 3 Continent cells, Old Forest on 3 by 1 Country cells. A place
-- that fits in one cell (Haven, Bramblemaw's Lair, Burnt Hills) opens the grid inside that cell, as before.
-- New: rpg_map_view_block (the body of rpg_map_view moved here and taught blocks of any size up to one grid and
-- places shown whole; a grid drawn fine also carries the smaller places that reach into its cells, so a place shown
-- whole keeps the small places its grids mark), rpg_map_place_block, rpg_map_place_link (where a place opens),
-- rpg_map_place_view (the read for a place shown whole; the kids login opens only a place the group has found or
-- knows). Changed in place: rpg_map_view (reads rpg_map_view_block for the whole grid: the same read as before plus
-- origin, the world's detail says it wraps, and each place's view is where it now opens), rpg_map_found (a block may
-- run past the east or west end of the world). No table or column changes, no drops, no settings.

CREATE OR REPLACE FUNCTION public.rpg_map_found(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block of one grid the group has found (Peter 2026-10-03, 2A): any part of the cell lies within
-- sight_squares (3,885 squares, 2.7 miles) of a stretch some player character walked (rpg_map_trails), counted the
-- way the game counts distance, the larger of the two gaps. A cell of a coarse grid is found once any of it is seen.
-- A block may run past the east or west end of the world (a place shown whole, rpg_map_view_block): a cell past the
-- end is the cell of the same ground round the world, and keeps the x it was asked by.
WITH lad AS (SELECT l.cell::bigint AS cell, l.across FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     sg AS (SELECT s.value::bigint AS sight FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'sight_squares'),
     seg AS MATERIALIZED (
       SELECT t.x0, t.y0, t.x1, t.y1 FROM public.rpg_map_trails() t CROSS JOIN lad CROSS JOIN sg
        WHERE (p_x0 < 0 OR p_x0 + p_cols > lad.across
               OR greatest(t.x0, t.x1) >= p_x0 * lad.cell + 1 - sg.sight AND least(t.x0, t.x1) <= (p_x0 + p_cols) * lad.cell + sg.sight)
          AND greatest(t.y0, t.y1) >= p_y0 * lad.cell + 1 - sg.sight AND least(t.y0, t.y1) <= (p_y0 + p_rows) * lad.cell + sg.sight)
SELECT gx, gy
  FROM lad CROSS JOIN sg CROSS JOIN generate_series(p_x0, p_x0 + p_cols - 1) AS gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy
 CROSS JOIN LATERAL (SELECT mod(mod(gx, lad.across) + lad.across, lad.across) AS wx) w
 WHERE EXISTS (SELECT 1 FROM seg WHERE public.rpg_seg_box(seg.x0, seg.y0, seg.x1, seg.y1,
                                                          w.wx * lad.cell + 1 - sg.sight, gy * lad.cell + 1 - sg.sight,
                                                          (w.wx + 1) * lad.cell + sg.sight, (gy + 1) * lad.cell + sg.sight));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_block(p_place uuid)
 RETURNS TABLE(level integer, x0 integer, y0 integer, cols integer, rows integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The block of cells that shows a place whole (Peter 2026-10-03: Westerwold is a massive continent, and its
-- Continent grid showed only a part of it): the cells the box round its oval reaches into, on the finest grid above
-- its own kind where they fit in one grid's worth of cells (12 across and 12 down; on the world grid 12 by 6).
-- level = that grid; x0, y0 = the first cell, counted across the whole world (x0 is below 0 when the place runs past
-- the west end of the world); cols, rows = cells across and down. Westerwold (12,690,432 by 13,747,968 squares round
-- 7,216,128, 8,833,536): 5 by 6 cells of the world grid from its first cell. Havenmark (a country): 5 by 3
-- Continent cells. Old Forest (a region): 3 by 1 Country cells. Haven (a city) fits in one Region cell. Nothing when
-- no grid holds it (a land wider than the world).
SELECT l.level, b.x0, b.y0, b.x1 - b.x0 + 1, b.y1 - b.y0 + 1
  FROM public.rpg_creatures c
  JOIN public.rpg_map_ladder() l ON l.level < c.place_level
 CROSS JOIN LATERAL (SELECT floor((c.place_x - c.place_w / 2.0) / l.cell)::integer AS x0,
                            ceil((c.place_x + c.place_w / 2.0) / l.cell)::integer - 1 AS x1,
                            greatest(floor((c.place_y - c.place_h / 2.0) / l.cell)::integer, 0) AS y0,
                            least(ceil((c.place_y + c.place_h / 2.0) / l.cell)::integer - 1, l.down - 1) AS y1) b
 WHERE c.id = p_place AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
   AND b.x1 - b.x0 + 1 <= l.cols AND b.y1 - b.y0 + 1 <= l.rows
 ORDER BY l.level DESC
 LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_link(p_place uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the Maps tab opens a place. A place that fits in one cell of the grid of its block (rpg_map_place_block)
-- opens the grid inside that cell, named the way any grid is (5-12762-5982: the City grid that holds Haven); a
-- bigger one opens shown whole, p-<its id> (rpg_map_place_view). Nothing, the world, when no grid holds it.
SELECT CASE WHEN b.cols = 1 AND b.rows = 1
            THEN (b.level + 1)::text || '-' || mod(mod(b.x0, l.across) + l.across, l.across)::text || '-' || b.y0::text
            ELSE 'p-' || p_place::text END
  FROM public.rpg_map_place_block(p_place) b
  JOIN public.rpg_map_ladder() l ON l.level = b.level;
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
-- places that name the land, the smallest of each kind), grounds = each kind of unnamed ground with its name and,
-- when it has one, its movement penalty in words, and the ladder of grids in words.
-- The world and a place shown whole also carry detail: every cell of the grid one level down inside the block (for
-- the world, the Continent grids: 144 across and 72 down), one character a cell (~ sea, . open land, t forest, h
-- hills, m mountains, else the character numbered 256 + the place's spot in detail.places, counted from 0), so they
-- are drawn as fine as the grids inside them; wrap = the east edge of the drawing meets its west edge (the world
-- only); marks = the smaller places reaching into a cell of the detail, by its "x,y" counted from 0 at the top-left
-- corner, the same as the marks of a cell.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped. journey = the open journey, if any (a session played on the world map): its clock in words,
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
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || wx.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(wx.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) c
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
           SELECT c.x, c.y, c.kind, c.place_id, c.marks,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM public.rpg_map_cells(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) c
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' ELSE CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.' WHEN 'forest' THEN 't'
                                                   WHEN 'hills' THEN 'h' WHEN 'mountains' THEN 'm'
                                                   ELSE chr(255 + array_position(u.ids, d.place_id)) END END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'wrap', p_place IS NULL, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y),
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
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_ground_text(c.place_forest, c.place_penalty) END,
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

  SELECT jsonb_strip_nulls(jsonb_build_object(
           'sea', jsonb_build_object('name', 'Sea'),
           'land', jsonb_build_object('name', 'Open land'),
           'forest', jsonb_build_object('name', 'Forest', 'penalty', CASE WHEN g.forest > 0 THEN public.rpg_map_ground_text(false, g.forest) END),
           'hills', jsonb_build_object('name', 'Hills', 'penalty', CASE WHEN g.hills > 0 THEN public.rpg_map_ground_text(false, g.hills) END),
           'mountains', jsonb_build_object('name', 'Mountains', 'penalty', CASE WHEN g.mountains > 0 THEN public.rpg_map_ground_text(false, g.mountains) END)))
    INTO v_grounds
    FROM (SELECT (SELECT r.penalty FROM public.rpg_map_ground('forest') r) AS forest,
                 (SELECT r.penalty FROM public.rpg_map_ground('hills') r) AS hills,
                 (SELECT r.penalty FROM public.rpg_map_ground('mountains') r) AS mountains) g;

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

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read: one whole grid of the world map. p_level 1 is the world; a deeper grid is named by its
-- level and by the cell of the grid above that it fills, counted across the whole world: 3, 88, 41 is the Country
-- grid inside cell 88, 41 of the Continent grids. The grid is read as the block of all its cells (12 by 12, the world
-- 12 by 6) by rpg_map_view_block, the one home of what the Maps tab shows and of what the kids login sees of it.
DECLARE
  v_l record;
BEGIN
  PERFORM public.require_login('family');
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = coalesce(p_level, 1);
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  IF coalesce(p_x, 0) NOT BETWEEN 0 AND v_l.across / v_l.cols - 1 OR coalesce(p_y, 0) NOT BETWEEN 0 AND v_l.down / v_l.rows - 1 THEN
    RAISE EXCEPTION 'that grid is off the map';
  END IF;
  RETURN public.rpg_map_view_block(v_l.level, coalesce(p_x, 0) * v_l.cols, coalesce(p_y, 0) * v_l.rows, v_l.cols, v_l.rows, NULL);
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_view(p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab opened on a place, shown whole (Peter 2026-10-03). The block of cells that holds all of the place
-- (rpg_map_place_block) is read like any grid (rpg_map_view_block): drawn one level finer, with the way back up
-- through the lands that hold it and the places one level down inside it on the list. Westerwold opens on 5 by 6
-- cells of the world grid. A place that fits in one cell opens the grid inside that cell, as rpg_map_view reads it
-- (Haven: the City grid 5-12762-5982); a land wider than the world opens the world. The kids login opens only a
-- place the group has found or knows.
DECLARE
  v_b      record;
  v_across integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_creatures c
                  WHERE c.id = p_place AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL) THEN
    RAISE EXCEPTION 'that place is not on the map';
  END IF;
  IF NOT public.family_is_parent() AND NOT (p_place = ANY (public.rpg_map_known_places()) OR public.rpg_map_place_seen(p_place)) THEN
    RAISE EXCEPTION 'that place is not on your map yet';
  END IF;
  SELECT * INTO v_b FROM public.rpg_map_place_block(p_place);
  IF NOT FOUND THEN RETURN public.rpg_map_view(1, 0, 0); END IF;
  IF v_b.cols = 1 AND v_b.rows = 1 THEN
    SELECT l.across INTO v_across FROM public.rpg_map_ladder() l WHERE l.level = v_b.level;
    RETURN public.rpg_map_view(v_b.level + 1, mod(mod(v_b.x0, v_across) + v_across, v_across), v_b.y0);
  END IF;
  RETURN public.rpg_map_view_block(v_b.level, v_b.x0, v_b.y0, v_b.cols, v_b.rows, p_place);
END $function$;

REVOKE ALL ON FUNCTION public.rpg_map_view_block(integer, integer, integer, integer, integer, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_place_block(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_place_link(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_place_view(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_view_block(integer, integer, integer, integer, integer, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_place_block(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_place_link(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_place_view(uuid) TO authenticated, service_role;

