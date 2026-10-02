-- roleplaying_map1b_layers_icons_detail (Peter 2026-10-02, his corrections to step 1 of the world map): icons on
-- the grid, each grid lists the places one level down (the world lists continents, a continent countries, a country
-- regions, and so on), and the world is drawn as fine as the grids inside it so it is the largest map.
-- Additive: two new columns on the cards table (the kind of place a card is, and its icon), one new function
-- (rpg_map_heights), the nine places get a level and an icon. Three existing functions are replaced in place with
-- the same names and arguments: rpg_creatures_place_check (a place now needs a level), rpg_map_cells (marks follow
-- the grid's layer, and heights come a block at a time) and rpg_map_view (icon, list, detail).
-- rpg_map_height (one point at a time) is left as it is: nothing calls it after this, and dropping it is Peter's call.

ALTER TABLE public.rpg_creatures
  ADD COLUMN IF NOT EXISTS place_level integer,
  ADD COLUMN IF NOT EXISTS place_icon text;
COMMENT ON COLUMN public.rpg_creatures.place_level IS 'Place cards only: the kind of place it is, as a level of the map ladder (rpg_map_ladder): 2 a continent, 3 a country, 4 a region, 5 a city, 6 a district, 7 a battle grid. The grid one level up lists it, and it opens on the grid of its own level around its center.';
COMMENT ON COLUMN public.rpg_creatures.place_icon IS 'Place cards only: the small picture the map draws for it (a tree for a forest, a mountain for hills). None = its color alone.';

CREATE OR REPLACE FUNCTION public.rpg_creatures_place_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A place is a card under the Place card, and only a place has a spot on the world map. A place needs a center
-- (place_x, place_y, in world squares from the north-west corner) on the world, a size (place_w, place_h, in
-- squares) of 1 square up to the whole world, and a level (place_level): the kind of place it is, named by the grid
-- of the map ladder that is about it, 2 a continent, 3 a country, 4 a region, 5 a city, 6 a district, 7 a battle
-- grid. Its ground is a movement penalty 0 to 9 (0 when not given) and forest or not (not, when not given). It may
-- carry an icon (place_icon), the small picture the map draws for it. A place made from another place sits inside
-- it and is no bigger a kind of place: the Cursed Road has its center in the Old Forest, and a country is never
-- made from a city. The Place card itself and every card that is not a place carry none of these.
DECLARE
  v_world integer;
  v_last  integer;
  v_p     record;
BEGIN
  IF NEW.parent_id IS NULL OR NOT public.rpg_is_place_card(NEW.parent_id) THEN
    IF NEW.place_x IS NOT NULL OR NEW.place_y IS NOT NULL OR NEW.place_w IS NOT NULL OR NEW.place_h IS NOT NULL
       OR NEW.place_penalty IS NOT NULL OR NEW.place_forest IS NOT NULL
       OR NEW.place_level IS NOT NULL OR NEW.place_icon IS NOT NULL THEN
      RAISE EXCEPTION '% is not a place, so it has no spot on the map', NEW.name;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.place_x IS NULL OR NEW.place_y IS NULL OR NEW.place_w IS NULL OR NEW.place_h IS NULL THEN
    RAISE EXCEPTION '% is a place, so it needs a center and a size', NEW.name;
  END IF;
  NEW.place_penalty := coalesce(NEW.place_penalty, 0);
  NEW.place_forest  := coalesce(NEW.place_forest, false);
  NEW.place_icon    := nullif(btrim(NEW.place_icon), '');
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  IF NEW.place_x NOT BETWEEN 0 AND v_world - 1 OR NEW.place_y NOT BETWEEN 0 AND v_world / 2 - 1 THEN
    RAISE EXCEPTION '%: its center is off the world', NEW.name;
  END IF;
  IF NEW.place_w NOT BETWEEN 1 AND v_world OR NEW.place_h NOT BETWEEN 1 AND v_world / 2 THEN
    RAISE EXCEPTION '%: a place is at least 1 square and no bigger than the world', NEW.name;
  END IF;
  IF NEW.place_penalty NOT BETWEEN 0 AND 9 THEN
    RAISE EXCEPTION '%: a movement penalty is 0 to 9', NEW.name;
  END IF;
  IF NEW.place_level IS NULL OR NEW.place_level NOT BETWEEN 2 AND v_last THEN
    RAISE EXCEPTION '% is a place, so it needs a level: %', NEW.name,
      (SELECT string_agg(l.level::text || ' a ' || lower(l.name), ', ' ORDER BY l.level) FROM public.rpg_map_ladder() l WHERE l.level > 1);
  END IF;
  IF char_length(NEW.place_icon) > 8 THEN
    RAISE EXCEPTION '%: an icon is one small picture, not words', NEW.name;
  END IF;
  SELECT p.name, p.place_x, p.place_y, p.place_w, p.place_h, p.place_level INTO v_p FROM public.rpg_creatures p WHERE p.id = NEW.parent_id;
  IF v_p.place_w IS NOT NULL AND NOT public.rpg_map_covers(NEW.place_x, NEW.place_y, v_p.place_x, v_p.place_y, v_p.place_w, v_p.place_h, v_world) THEN
    RAISE EXCEPTION '% sits outside %, the place it is made from', NEW.name, v_p.name;
  END IF;
  IF v_p.place_level IS NOT NULL AND NEW.place_level < v_p.place_level THEN
    RAISE EXCEPTION '% is made from %, so it cannot be a bigger kind of place than it', NEW.name, v_p.name;
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE TRIGGER rpg_creatures_place_check
  BEFORE INSERT OR UPDATE OF parent_id, place_x, place_y, place_w, place_h, place_penalty, place_forest, place_level, place_icon
  ON public.rpg_creatures FOR EACH ROW EXECUTE FUNCTION public.rpg_creatures_place_check();

-- The nine places get the kind of place they are and an icon (Peter corrects). Parents first, then the two places
-- made from the Old Forest. The icons are written as code points so this file stays plain text:
-- houses, evergreen tree, derelict house, mountain, valley park, fog, cactus, footprints, skull.
UPDATE public.rpg_creatures c
   SET place_level = v.lvl, place_icon = v.icon
  FROM (VALUES ('haven', 5, U&'\+01F3D8\FE0F'), ('old_forest', 4, U&'\+01F332'),
               ('abandoned_borderlands', 4, U&'\+01F3DA\FE0F'), ('burnt_hills', 4, U&'\26F0\FE0F'),
               ('mossback_valley', 4, U&'\+01F3DE\FE0F'), ('the_fog', 4, U&'\+01F32B\FE0F'),
               ('thornfields', 4, U&'\+01F335')) AS v(key, lvl, icon)
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = v.key AND c.place_w IS NOT NULL AND c.place_level IS NULL;

UPDATE public.rpg_creatures c
   SET place_level = v.lvl, place_icon = v.icon
  FROM (VALUES ('cursed_road', 4, U&'\+01F463'), ('bramblemaw_lair', 5, U&'\+01F480')) AS v(key, lvl, icon)
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = v.key AND c.place_w IS NOT NULL AND c.place_level IS NULL;

CREATE OR REPLACE FUNCTION public.rpg_map_heights(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, height double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- How high unnamed ground stands at the center of every cell in a block of cells of one grid of the world map.
-- Land where the height is at or above the sea level (rpg_settings map_sea_level), sea below it. The one home of
-- land and sea, worked out when asked and never stored.
-- Every grid from the world down to p_level adds two layers of fixed-seed rolls (rpg_map_roll): one on points 3
-- cells apart and one on every cell. A layer is read by blending the four rolls around the cell center, a roll
-- counts as its number less 50.5, and each layer counts map_detail_share (0.5) of the layer before it. So the grids
-- above set the shape and each grid down adds finer coast, and a land cell opens onto mostly land.
-- At a share of 0.5 the layers weigh 1, 0.5, 0.25, 0.125 and so on: rolls of 80 and 30 on the two world layers
-- alone give 1 x 29.5 + 0.5 x -20.5 = 19.25, above the sea level of 17.1, so land.
-- A whole block is one call so that every roll is made once (rl) and shared by all the cells around it: the world
-- drawn fine is 10,368 cells off about 12,000 rolls, not 166,000. The rolls stay in one list outside the joins and
-- only the small sums are sorted. The map wraps east to west; north and south it stops at the edge.
WITH cfg AS (
       SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
              (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) AS cell),
     lay AS MATERIALIZED (
       -- One row a layer, coarsest first. n = its number; f = cells of this grid from one of its points to the
       -- next; nx, ny = its points around and down the world; wt = what it counts; a_lo, b_lo = the first point
       -- the block needs; wd, ht = points across and down the block; off = the rolls of the layers before it.
       SELECT q.n, q.seed, q.f, q.nx, q.ny, q.wt, q.a_lo, q.b_lo, q.wd, q.ht,
              (sum(q.wd * q.ht) OVER (ORDER BY q.n) - q.wd * q.ht)::integer AS off
         FROM (SELECT (l.level - 1) * 2 + v.i AS n, cfg.seed, k.f, l.across / v.m AS nx, l.down / v.m AS ny,
                      power(cfg.share, (l.level - 1) * 2 + v.i - 1) AS wt,
                      floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer AS a_lo,
                      floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer AS b_lo,
                      floor((p_x0 + p_cols - 0.5::double precision) / k.f - 0.5)::integer - floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS wd,
                      floor((p_y0 + p_rows - 0.5::double precision) / k.f - 0.5)::integer - floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS ht
                 FROM cfg CROSS JOIN public.rpg_map_ladder() l CROSS JOIN (VALUES (1, 3), (2, 1)) AS v(i, m)
                CROSS JOIN LATERAL (SELECT v.m * (l.cell / cfg.cell) AS f) k
                WHERE l.level <= p_level) q),
     rl AS MATERIALIZED (
       -- Every roll the block needs, made once and kept in one list: layer by layer, each layer row by row.
       SELECT ARRAY(SELECT public.rpg_map_roll(l.seed, l.n, mod(mod(l.a_lo + i, l.nx) + l.nx, l.nx), least(greatest(l.b_lo + j, 0), l.ny - 1))
                      FROM lay l CROSS JOIN LATERAL generate_series(0, l.ht - 1) AS j CROSS JOIN LATERAL generate_series(0, l.wd - 1) AS i
                     ORDER BY l.n, j, i) AS rolls),
     ax AS MATERIALIZED (
       -- One row a layer and column of the block. i = where the point just west of the cell center sits in a row
       -- of the layer's rolls; sx = how far east of that point the center is, eased (0 on the point, 1 on the next).
       SELECT l.n, gx, a.a - l.a_lo AS i, (u.u - a.a) * (u.u - a.a) * (3 - 2 * (u.u - a.a)) AS sx
         FROM lay l CROSS JOIN generate_series(p_x0, p_x0 + p_cols - 1) AS gx
        CROSS JOIN LATERAL (SELECT (gx + 0.5::double precision) / l.f - 0.5 AS u) u
        CROSS JOIN LATERAL (SELECT floor(u.u)::integer AS a) a),
     ay AS MATERIALIZED (
       -- The same down the block. j = where the row of points just north of the cell center starts in the list of
       -- rolls; sy = how far south of that row the center is, eased.
       SELECT l.n, gy, l.off + (b.b - l.b_lo) * l.wd AS j, (v.v - b.b) * (v.v - b.b) * (3 - 2 * (v.v - b.b)) AS sy
         FROM lay l CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy
        CROSS JOIN LATERAL (SELECT (gy + 0.5::double precision) / l.f - 0.5 AS v) v
        CROSS JOIN LATERAL (SELECT floor(v.v)::integer AS b) b),
     term AS MATERIALIZED (
       -- One row a cell and layer: what that layer adds to the height of the cell, from the four rolls around it.
       SELECT ax.gx, ay.gy, l.n,
              l.wt * (((SELECT rl.rolls FROM rl)[ay.j + ax.i + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + 2] * ax.sx) * (1 - ay.sy)
                    + ((SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 2] * ax.sx) * ay.sy - 50.5) AS part
         FROM lay l
         JOIN ax ON ax.n = l.n
         JOIN ay ON ay.n = l.n)
SELECT t.gx, t.gy, sum(t.part ORDER BY t.n)
  FROM term t
 GROUP BY t.gx, t.gy;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The ground of any block of cells of any grid of the world map, worked out when asked and never stored. The one
-- home of what a cell is; a single square under a piece is the same call at the battle grid, 1 by 1.
-- x, y = the cell, counted across the whole world at that level. p_x0, p_y0 = the first cell of the block.
-- A place fills a cell of a grid when it covers the center of the cell its own center falls in. A place that fills
-- is ground: a cell belongs to the smallest such place whose oval covers its center (kind place, place_id that
-- card). With no place there it is unnamed ground: land when its height (rpg_map_heights) is at or above the sea
-- level, else sea.
-- marks = the places that reach into the cell but are too small or too thin to fill any cell of this grid, smallest
-- first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this grid is about are
-- marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is not marked on a
-- Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     sea AS (SELECT s.value::double precision AS lvl FROM public.rpg_settings s
              WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level'),
     pl AS MATERIALIZED (
       SELECT q.id, q.place_x, q.place_y, q.place_w, q.place_h, q.area, q.fills
         FROM (SELECT c.id, c.place_x, c.place_y, c.place_w, c.place_h, c.place_level, c.place_w::bigint * c.place_h AS area,
                      public.rpg_map_covers(((c.place_x / lad.cell + 0.5) * lad.cell)::double precision, ((c.place_y / lad.cell + 0.5) * lad.cell)::double precision,
                                            c.place_x, c.place_y, c.place_w, c.place_h, lad.world) AS fills
                 FROM public.rpg_creatures c CROSS JOIN lad
                WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
                  AND public.rpg_map_touches(p_x0::double precision * lad.cell, p_y0::double precision * lad.cell,
                                             (p_x0 + p_cols)::double precision * lad.cell, (p_y0 + p_rows)::double precision * lad.cell,
                                             c.place_x, c.place_y, c.place_w, c.place_h, lad.world)) q
        WHERE q.fills OR q.place_level <= p_level + 1),
     g AS MATERIALIZED (
       SELECT h.x AS gx, h.y AS gy, h.height, lad.cell, lad.world,
              ((h.x + 0.5) * lad.cell)::double precision AS cx, ((h.y + 0.5) * lad.cell)::double precision AS cy
         FROM lad CROSS JOIN public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h)
SELECT g.gx, g.gy,
       CASE WHEN count(*) FILTER (WHERE p.fills) > 0 THEN 'place'
            WHEN g.height >= (SELECT sea.lvl FROM sea) THEN 'land'
            ELSE 'sea' END,
       (array_agg(p.id ORDER BY p.area, p.id) FILTER (WHERE p.fills))[1],
       coalesce(array_agg(p.id ORDER BY p.area, p.id) FILTER (WHERE NOT p.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN pl p
    ON CASE WHEN p.fills
            THEN public.rpg_map_covers(g.cx, g.cy, p.place_x, p.place_y, p.place_w, p.place_h, g.world)
            ELSE public.rpg_map_touches(g.gx::double precision * g.cell, g.gy::double precision * g.cell,
                                        (g.gx + 1)::double precision * g.cell, (g.gy + 1)::double precision * g.cell,
                                        p.place_x, p.place_y, p.place_w, p.place_h, g.world) END
 GROUP BY g.gx, g.gy, g.height
 ORDER BY g.gy, g.gx;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The Maps tab in one read, game master only: one grid of the world map, drawn from the place cards and the
-- fixed-seed land and sea (rpg_map_cells). p_level 1 is the world; a deeper grid is named by its level and by the
-- cell of the grid above that it fills, counted across the whole world: 3, 94, 16 is the Country grid inside cell
-- 94, 16 of the Continent grids.
-- Returns the grid (level, name, title, cols, rows, scale), the way back up (crumbs), the grid next door each way
-- (moves), every cell in reading order (x, y, its name like C5, kind sea / land / place, place = the card it
-- belongs to, marks = other place cards reaching into it, open = the grid inside it), every place card (name,
-- color, icon, size, ground, the place it is inside, level = the kind of place it is, view = the grid of its own
-- level around its center, listed = it belongs on this grid's list), list = what this grid lists, the places one
-- level down that reach into it (the world lists continents, a continent countries, a country regions, a region
-- cities, a city districts, a district battle grids; a battle grid lists nothing), the names of unnamed ground,
-- and the ladder of grids in words.
-- The world also carries detail: every cell of the Continent grids inside it, 144 across and 72 down, one
-- character a cell (~ sea, . land, else the character numbered 256 + the place's spot in detail.places, counted
-- from 0), so the world is drawn as fine as the grids inside it.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := coalesce(p_x, 0);
  v_y         integer := coalesce(p_y, 0);
  v_x0        integer := 0;
  v_y0        integer := 0;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_dc        integer;
  v_dr        integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_scale     text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sees the map'; END IF;
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = coalesce(p_level, 1);
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF v_l.level = 1 THEN
    IF v_x <> 0 OR v_y <> 0 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  ELSE
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    IF v_x NOT BETWEEN 0 AND v_up_across - 1 OR v_y NOT BETWEEN 0 AND v_up_down - 1 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
    v_x0 := v_x * v_l.cols;
    v_y0 := v_y * v_l.rows;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'x', c.x - v_x0 + 1, 'y', c.y - v_y0 + 1,
           'name', public.rpg_square_name(c.x - v_x0 + 1, c.y - v_y0 + 1),
           'kind', c.kind, 'place', c.place_id,
           'marks', CASE WHEN cardinality(c.marks) > 0 THEN to_jsonb(c.marks) END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || c.x::text || '-' || c.y::text END))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_cells(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) c;

  IF v_l.level = 1 THEN
    SELECT l.across, l.down INTO v_dc, v_dr FROM public.rpg_map_ladder() l WHERE l.level = 2;
    WITH d AS MATERIALIZED (SELECT c.x, c.y, c.kind, c.place_id FROM public.rpg_map_cells(2, 0, 0, v_dc, v_dr) c),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id) q),
         ln AS (SELECT d.y, string_agg(CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.'
                                                   ELSE chr(255 + array_position(u.ids, d.place_id)) END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y))
      INTO v_detail
      FROM ln;
  END IF;

  SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                        ELSE jsonb_build_object(
                          'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                          'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                   ORDER BY l.level)
    INTO v_crumbs
    FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
   WHERE l.level <= v_l.level;

  v_scale := public.rpg_map_length_text(v_l.span)
          || CASE WHEN v_l.level = 1 THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', coalesce(nullif(concat_ws(' · ', CASE WHEN c.place_forest THEN 'forest' END,
                                               CASE WHEN c.place_penalty > 0 THEN 'movement penalty ' || c.place_penalty::text END), ''), 'open ground'),
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', c.lore,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text,
           'listed', c.place_level = v_l.level + 1
                     AND public.rpg_map_touches(v_x0::double precision * v_l.cell, v_y0::double precision * v_l.cell,
                                                (v_x0 + v_l.cols)::double precision * v_l.cell, (v_y0 + v_l.rows)::double precision * v_l.cell,
                                                c.place_x, c.place_y, c.place_w, c.place_h, v_world))
         ORDER BY c.sort_order, c.name)
    INTO v_places
    FROM public.rpg_creatures c
    JOIN public.rpg_map_ladder() f ON f.level = c.place_level
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1) q;

  SELECT jsonb_agg(jsonb_build_object('name', l.name, 'line',
           public.rpg_map_length_text(l.span)
           || CASE WHEN l.level = 1 THEN ' around, cells of '
                   WHEN l.level = v_last THEN ' across, squares of '
                   ELSE ' across, cells of ' END
           || public.rpg_map_length_text(l.cell)) ORDER BY l.level)
    INTO v_ladder
    FROM public.rpg_map_ladder() l;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', v_l.name, 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_l.cols, 'rows', v_l.rows, 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list,
    'grounds', jsonb_build_object('sea', 'Sea', 'land', 'Open land'),
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $fn$;

-- The new function is internal, like the rest of the map functions; only rpg_map_view is for logins.
REVOKE ALL ON FUNCTION public.rpg_map_heights(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_heights(integer, integer, integer, integer, integer) TO service_role;

