-- roleplaying_map1_world_drawn (Peter 2026-10-01 rulings; step 1 of the world map: the world drawn at every level,
-- game master only). The world is the size of the Earth, made of nested grids from the world down to a battle grid,
-- at actual sizes, and nothing is stored per square: a place is a card with a center and a size, and unnamed ground
-- is land or sea by a fixed-seed roll worked out level by level. Additive: new columns on the cards table, new
-- settings, new functions, ten new cards (Place and nine places). Two existing things change so the rest of the
-- game reads the same as before: rpg_creature_list gains one line (place cards stay off the Creatures tab, the way
-- object cards already do), and the Knowing Things rule card names Knowing Place as a third root.

ALTER TABLE public.rpg_creatures
  ADD COLUMN IF NOT EXISTS place_x integer,
  ADD COLUMN IF NOT EXISTS place_y integer,
  ADD COLUMN IF NOT EXISTS place_w integer,
  ADD COLUMN IF NOT EXISTS place_h integer,
  ADD COLUMN IF NOT EXISTS place_penalty integer,
  ADD COLUMN IF NOT EXISTS place_forest boolean;
COMMENT ON COLUMN public.rpg_creatures.place_x IS 'Place cards only: the center of the place, in world squares counted east from the west edge of the map (0 to 35,831,807).';
COMMENT ON COLUMN public.rpg_creatures.place_y IS 'Place cards only: the center of the place, in world squares counted south from the north edge of the map (0 to 17,915,903).';
COMMENT ON COLUMN public.rpg_creatures.place_w IS 'Place cards only: how wide the place is, west to east, in squares. The place is the oval that fits this width and height.';
COMMENT ON COLUMN public.rpg_creatures.place_h IS 'Place cards only: how tall the place is, north to south, in squares.';
COMMENT ON COLUMN public.rpg_creatures.place_penalty IS 'Place cards only: the movement penalty of its ground, 0 to 9, read the way a fight board square is (rpg_square_info).';
COMMENT ON COLUMN public.rpg_creatures.place_forest IS 'Place cards only: whether its ground is forest, read the way a fight board square is (rpg_square_info).';

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_world_miles', 24901.46, 'Miles around the world, the same as the Earth'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_seed', 7, 'The fixed seed every roll for unnamed land and sea starts from'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_sea_level', 17.1, 'Unnamed ground at or above this height is land and below it is sea (about 29 in 100 is land, like the Earth)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_detail_share', 0.5, 'Each layer of map rolls counts this share of the layer before it')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_ladder()
RETURNS TABLE(level integer, name text, cols integer, rows integer, cell integer, span integer, across integer, down integer)
LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $fn$
-- The ladder of grids the world map is made of, and the one home of its shape (Peter 2026-10-01): seven grids, the
-- world grid 12 cells across and 6 down (a flat map of the Earth is twice as wide as it is tall), every grid below
-- it 12 by 12, and each cell a whole grid one level down.
-- cols, rows = cells across and down one grid of this level; cell = squares along one side of one of its cells;
-- span = squares across one whole grid of this level; across, down = cells around and down the whole world.
-- 12 x 12 x 12 x 12 x 12 x 12 x 12 = 35,831,808 squares go around the world, so one square is the miles around the
-- world (rpg_settings map_world_miles, 24,901.46) x 5,280 / 35,831,808 = 3.669 feet.
-- World 24,901 miles around, cells of 2,075 miles; Continent 2,075 miles, cells of 172.9; Country 172.9, cells of
-- 14.41; Region 14.41, cells of 1.2; City 1.2 miles, cells of 528 feet; District 528 feet, cells of 44; Battle
-- grid 44 feet, squares of 3 ft 8 in.
SELECT l, (ARRAY['World', 'Continent', 'Country', 'Region', 'City', 'District', 'Battle grid'])[l],
       12, CASE WHEN l = 1 THEN 6 ELSE 12 END,
       (12 ^ (7 - l))::integer,
       CASE WHEN l = 1 THEN (12 ^ 7)::integer ELSE (12 ^ (8 - l))::integer END,
       (12 ^ l)::integer, ((12 ^ l) / 2)::integer
  FROM generate_series(1, 7) AS l;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_roll(p_seed integer, p_layer integer, p_x integer, p_y integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $fn$
-- One fixed-seed d100 for a point of the world map. The same seed, layer and point always roll the same number, so
-- nothing about unnamed ground is ever stored: md5 of seed:layer:x:y, its first 8 hex digits as a number, the
-- remainder after dividing by 100, plus 1. Seed 7, layer 1, point 0,0 always rolls the same 1 to 100.
SELECT ((('x' || substr(md5(p_seed::text || ':' || p_layer::text || ':' || p_x::text || ':' || p_y::text), 1, 8))::bit(32)::bigint % 100) + 1)::integer;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_covers(p_x double precision, p_y double precision, p_cx integer, p_cy integer, p_w integer, p_h integer, p_world integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
-- Whether a point of the world map lies inside a place: the oval p_w squares wide and p_h tall around its center.
-- The map wraps east to west, so the gap across is taken the short way round the world (p_world squares around).
-- A place 20 miles wide and 8 tall covers a point 9 miles east of its center and 1 mile north; not one 9 east, 3 north.
SELECT power(((p_x - p_cx) - p_world * floor((p_x - p_cx) / p_world + 0.5)) / (p_w / 2.0::double precision), 2)
     + power((p_y - p_cy) / (p_h / 2.0::double precision), 2) <= 1;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_touches(p_x0 double precision, p_y0 double precision, p_x1 double precision, p_y1 double precision, p_cx integer, p_cy integer, p_w integer, p_h integer, p_world integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $fn$
-- Whether a place reaches into a box of the world map (a cell, or a whole grid): the point of the box nearest the
-- center of the place lies inside its oval. The center is first moved whole trips round the world until it is the
-- nearest copy to the box, since the map wraps east to west.
SELECT power((least(greatest(p_cx + p_world * floor(((p_x0 + p_x1) / 2 - p_cx) / p_world + 0.5), p_x0), p_x1)
              - (p_cx + p_world * floor(((p_x0 + p_x1) / 2 - p_cx) / p_world + 0.5))) / (p_w / 2.0::double precision), 2)
     + power((least(greatest(p_cy::double precision, p_y0), p_y1) - p_cy) / (p_h / 2.0::double precision), 2) < 1;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_height(p_level integer, p_x double precision, p_y double precision)
RETURNS double precision LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- How high unnamed ground stands at a point of the world map, as seen from the grid at p_level. Land where the
-- height is at or above the sea level (rpg_settings map_sea_level), sea below it. The one home of land and sea.
-- Worked out level by level and never stored. Every grid from the world down to p_level adds two layers of fixed-
-- seed rolls (rpg_map_roll): one on points 3 cells apart and one on every cell. A layer is read by blending the
-- four rolls around the point, a roll counts as its number less 50.5, and each layer counts map_detail_share (0.5)
-- of the layer before it. So the grids above set the shape and each grid down adds finer coast, and a land cell
-- opens onto mostly land.
-- At a share of 0.5 the layers weigh 1, 0.5, 0.25, 0.125 and so on: rolls of 80 and 30 on the two world layers
-- alone give 1 x 29.5 + 0.5 x -20.5 = 19.25, above the sea level of 17.1, so land.
-- The map wraps east to west; north and south it stops at the edge.
DECLARE
  v_seed  integer := (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer;
  v_share double precision := (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision;
  v_h     double precision := 0;
  v_wt    double precision := 1;
  v_layer integer := 0;
  r       record;
  v_m     integer;
  v_s     integer;
  v_nx    integer;
  v_ny    integer;
  v_u     double precision;
  v_v     double precision;
  v_a     integer;
  v_b     integer;
  v_a0    integer;
  v_a1    integer;
  v_b0    integer;
  v_b1    integer;
  v_tx    double precision;
  v_ty    double precision;
  v_sx    double precision;
  v_sy    double precision;
  v_top   double precision;
  v_bot   double precision;
BEGIN
  FOR r IN SELECT l.cell, l.across, l.down FROM public.rpg_map_ladder() l WHERE l.level <= p_level ORDER BY l.level LOOP
    FOREACH v_m IN ARRAY ARRAY[3, 1] LOOP
      v_layer := v_layer + 1;
      v_s  := v_m * r.cell;
      v_nx := r.across / v_m;
      v_ny := r.down / v_m;
      v_u  := p_x / v_s - 0.5;
      v_v  := p_y / v_s - 0.5;
      v_a  := floor(v_u)::integer;
      v_b  := floor(v_v)::integer;
      v_tx := v_u - v_a;
      v_ty := v_v - v_b;
      v_sx := v_tx * v_tx * (3 - 2 * v_tx);
      v_sy := v_ty * v_ty * (3 - 2 * v_ty);
      v_a0 := mod(mod(v_a, v_nx) + v_nx, v_nx);
      v_a1 := mod(mod(v_a + 1, v_nx) + v_nx, v_nx);
      v_b0 := least(greatest(v_b, 0), v_ny - 1);
      v_b1 := least(greatest(v_b + 1, 0), v_ny - 1);
      v_top := public.rpg_map_roll(v_seed, v_layer, v_a0, v_b0) * (1 - v_sx) + public.rpg_map_roll(v_seed, v_layer, v_a1, v_b0) * v_sx;
      v_bot := public.rpg_map_roll(v_seed, v_layer, v_a0, v_b1) * (1 - v_sx) + public.rpg_map_roll(v_seed, v_layer, v_a1, v_b1) * v_sx;
      v_h  := v_h + v_wt * (v_top * (1 - v_sy) + v_bot * v_sy - 50.5);
      v_wt := v_wt * v_share;
    END LOOP;
  END LOOP;
  RETURN v_h;
END $fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_length_text(p_squares numeric)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A length on the world map in plain words, from squares. One square is the miles around the world x 5,280 /
-- the squares around it. A mile or more reads in miles (24,901 miles, 172.9 miles, 14.41 miles, 1.2 miles),
-- under a mile in whole feet (528 feet), and under 10 feet in feet and inches (3 ft 8 in).
WITH f AS (SELECT p_squares * (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_world_miles') * 5280
                  / (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1) AS feet)
SELECT CASE
         WHEN f.feet >= 5280000 THEN to_char(round(f.feet / 5280), 'FM999,999,999') || ' miles'
         WHEN f.feet >= 528000  THEN trim_scale(round(f.feet / 5280, 1))::text || ' miles'
         WHEN f.feet >= 5280    THEN trim_scale(round(f.feet / 5280, 2))::text || CASE WHEN round(f.feet / 5280, 2) = 1 THEN ' mile' ELSE ' miles' END
         WHEN f.feet >= 10      THEN to_char(round(f.feet), 'FM999,999') || ' feet'
         WHEN round((f.feet - floor(f.feet)) * 12) = 12 THEN (floor(f.feet) + 1)::integer::text || ' ft 0 in'
         ELSE floor(f.feet)::integer::text || ' ft ' || round((f.feet - floor(f.feet)) * 12)::integer::text || ' in'
       END
  FROM f;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_is_place_card(p_card uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  -- True for the Place card and every card under it (Old Forest, Haven, and the rest): the cards the world map is drawn from.
  -- Place cards are not creatures: they stay off the Creatures tab (rpg_creature_list) and live on the Maps tab
  -- (rpg_map_view). Also read by rpg_creatures_place_check.
  SELECT p_card IS NOT NULL AND (SELECT c.id FROM public.rpg_creatures c
                                  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'place')
                                 = ANY (public.rpg_template_chain(p_card));
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_creatures_place_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A place is a card under the Place card, and only a place has a spot on the world map. A place needs a center
-- (place_x, place_y, in world squares from the north-west corner) on the world and a size (place_w, place_h, in
-- squares) of 1 square up to the whole world; its ground is a movement penalty 0 to 9 (0 when not given) and forest
-- or not (not, when not given). A place made from another place sits inside it: the Cursed Road has its center in
-- the Old Forest. The Place card itself and every card that is not a place carry none of these numbers.
DECLARE
  v_world integer;
  v_p     record;
BEGIN
  IF NEW.parent_id IS NULL OR NOT public.rpg_is_place_card(NEW.parent_id) THEN
    IF NEW.place_x IS NOT NULL OR NEW.place_y IS NOT NULL OR NEW.place_w IS NOT NULL OR NEW.place_h IS NOT NULL
       OR NEW.place_penalty IS NOT NULL OR NEW.place_forest IS NOT NULL THEN
      RAISE EXCEPTION '% is not a place, so it has no spot on the map', NEW.name;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.place_x IS NULL OR NEW.place_y IS NULL OR NEW.place_w IS NULL OR NEW.place_h IS NULL THEN
    RAISE EXCEPTION '% is a place, so it needs a center and a size', NEW.name;
  END IF;
  NEW.place_penalty := coalesce(NEW.place_penalty, 0);
  NEW.place_forest  := coalesce(NEW.place_forest, false);
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF NEW.place_x NOT BETWEEN 0 AND v_world - 1 OR NEW.place_y NOT BETWEEN 0 AND v_world / 2 - 1 THEN
    RAISE EXCEPTION '%: its center is off the world', NEW.name;
  END IF;
  IF NEW.place_w NOT BETWEEN 1 AND v_world OR NEW.place_h NOT BETWEEN 1 AND v_world / 2 THEN
    RAISE EXCEPTION '%: a place is at least 1 square and no bigger than the world', NEW.name;
  END IF;
  IF NEW.place_penalty NOT BETWEEN 0 AND 9 THEN
    RAISE EXCEPTION '%: a movement penalty is 0 to 9', NEW.name;
  END IF;
  SELECT p.name, p.place_x, p.place_y, p.place_w, p.place_h INTO v_p FROM public.rpg_creatures p WHERE p.id = NEW.parent_id;
  IF v_p.place_w IS NOT NULL AND NOT public.rpg_map_covers(NEW.place_x, NEW.place_y, v_p.place_x, v_p.place_y, v_p.place_w, v_p.place_h, v_world) THEN
    RAISE EXCEPTION '% sits outside %, the place it is made from', NEW.name, v_p.name;
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE TRIGGER rpg_creatures_place_check
  BEFORE INSERT OR UPDATE OF parent_id, place_x, place_y, place_w, place_h, place_penalty, place_forest
  ON public.rpg_creatures FOR EACH ROW EXECUTE FUNCTION public.rpg_creatures_place_check();

CREATE OR REPLACE FUNCTION public.rpg_map_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The ground of any block of cells of any grid of the world map, worked out when asked and never stored. The one
-- home of what a cell is; a single square under a piece is the same call at the battle grid, 1 by 1.
-- x, y = the cell, counted across the whole world at that level. p_x0, p_y0 = the first cell of the block.
-- A cell belongs to the smallest place whose oval covers its center (kind place, place_id that card). With no place
-- there it is unnamed ground: land when rpg_map_height at its center is at or above the sea level, else sea.
-- marks = the places that reach into the cell but are too small or too thin to fill any cell of this grid,
-- smallest first: a village in a 14-mile cell, a road 29 feet wide crossing a 1.2-mile cell. A place fills a cell
-- of a grid when it covers the center of the cell its own center falls in; one that does is drawn as ground only.
WITH lad AS (SELECT l.cell, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     sea AS (SELECT s.value::double precision AS lvl FROM public.rpg_settings s
              WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level'),
     pl AS MATERIALIZED (
       SELECT c.id, c.place_x, c.place_y, c.place_w, c.place_h, c.place_w::bigint * c.place_h AS area,
              public.rpg_map_covers(((c.place_x / lad.cell + 0.5) * lad.cell)::double precision, ((c.place_y / lad.cell + 0.5) * lad.cell)::double precision,
                                    c.place_x, c.place_y, c.place_w, c.place_h, lad.world) AS fills
         FROM public.rpg_creatures c CROSS JOIN lad
        WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
          AND public.rpg_map_touches(p_x0::double precision * lad.cell, p_y0::double precision * lad.cell,
                                     (p_x0 + p_cols)::double precision * lad.cell, (p_y0 + p_rows)::double precision * lad.cell,
                                     c.place_x, c.place_y, c.place_w, c.place_h, lad.world)),
     g AS MATERIALIZED (
       SELECT gx, gy, lad.cell, lad.world,
              ((gx + 0.5) * lad.cell)::double precision AS cx, ((gy + 0.5) * lad.cell)::double precision AS cy
         FROM lad, generate_series(p_x0, p_x0 + p_cols - 1) AS gx, generate_series(p_y0, p_y0 + p_rows - 1) AS gy),
     hit AS MATERIALIZED (
       SELECT g.gx, g.gy, p.id, p.area, p.fills,
              public.rpg_map_covers(g.cx, g.cy, p.place_x, p.place_y, p.place_w, p.place_h, g.world) AS covers
         FROM g JOIN pl p
           ON public.rpg_map_covers(g.cx, g.cy, p.place_x, p.place_y, p.place_w, p.place_h, g.world)
           OR public.rpg_map_touches(g.gx::double precision * g.cell, g.gy::double precision * g.cell,
                                     (g.gx + 1)::double precision * g.cell, (g.gy + 1)::double precision * g.cell,
                                     p.place_x, p.place_y, p.place_w, p.place_h, g.world))
SELECT g.gx, g.gy,
       CASE WHEN top.id IS NOT NULL THEN 'place'
            WHEN public.rpg_map_height(p_level, g.cx, g.cy) >= (SELECT sea.lvl FROM sea) THEN 'land'
            ELSE 'sea' END,
       top.id,
       coalesce((SELECT array_agg(h.id ORDER BY h.area, h.id) FROM hit h WHERE h.gx = g.gx AND h.gy = g.gy AND NOT h.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN LATERAL (SELECT h.id FROM hit h WHERE h.gx = g.gx AND h.gy = g.gy AND h.covers ORDER BY h.area, h.id LIMIT 1) top ON true
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
-- color, size, ground, the place it is inside, the grid it first fills a cell of, the view that opens on it, and
-- whether it is on this grid), the names of unnamed ground, and the ladder of grids in words.
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
  v_cells     jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
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
           'id', c.id, 'name', c.name, 'color', c.color,
           'ground', coalesce(nullif(concat_ws(' · ', CASE WHEN c.place_forest THEN 'forest' END,
                                               CASE WHEN c.place_penalty > 0 THEN 'movement penalty ' || c.place_penalty::text END), ''), 'open ground'),
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', c.lore,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', CASE WHEN f.level > 1 THEN f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text END,
           'here', public.rpg_map_touches(v_x0::double precision * v_l.cell, v_y0::double precision * v_l.cell,
                                          (v_x0 + v_l.cols)::double precision * v_l.cell, (v_y0 + v_l.rows)::double precision * v_l.cell,
                                          c.place_x, c.place_y, c.place_w, c.place_h, v_world))
         ORDER BY c.sort_order, c.name)
    INTO v_places
    FROM public.rpg_creatures c
    JOIN LATERAL (SELECT l.level, l.name, l.span FROM public.rpg_map_ladder() l
                   WHERE l.cell <= least(c.place_w, c.place_h) ORDER BY l.level LIMIT 1) f ON true
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;

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
    'cells', coalesce(v_cells, '[]'::jsonb), 'places', coalesce(v_places, '[]'::jsonb),
    'grounds', jsonb_build_object('sea', 'Sea', 'land', 'Open land'),
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $fn$;

-- The Place card, then the nine starting places at real sizes (Peter 2026-09-30: start from the creature haunts and
-- he corrects). Positions are world squares; one mile is 1,438.94 squares. Every card also gets its knowledge skill
-- (Knowing Place, Knowing Old Forest, ...) from the trigger that gives every card one.
INSERT INTO public.rpg_creatures (agency_id, key, name, sort_order)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'place', 'Place', 2000)
ON CONFLICT (agency_id, key) DO NOTHING;

INSERT INTO public.rpg_creatures (agency_id, key, name, parent_id, sort_order, color, lore, place_x, place_y, place_w, place_h, place_penalty, place_forest)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, top.id, v.sort_order, v.color, v.lore, v.x, v.y, v.w, v.h, v.penalty, v.forest
  FROM (VALUES
    ('haven', 'Haven', 2010, '#C9973F', 'The home village of the player characters. No card names one, so this one was added.',
     23546592, 4116960, 327, 218, 0, false),
    ('old_forest', 'Old Forest', 2020, '#3F6B3A', 'An old-growth forest about the size of Sherwood Forest in the Middle Ages. Old-growth forests are a haunt on the Bramblemaw card.',
     23525008, 4116960, 28779, 11512, 1, true),
    ('abandoned_borderlands', 'Abandoned Borderlands', 2030, '#B5A88A', 'Empty frontier country west of the Old Forest. Abandoned borderlands are a haunt on the Bramblemaw card.',
     23477523, 4119838, 57558, 21584, 0, false),
    ('burnt_hills', 'Burnt Hills', 2040, '#7A5548', 'The burnt hills where the Ashwing Harrier hunts.',
     23566449, 4112068, 17267, 7195, 2, false),
    ('mossback_valley', 'Mossback Valley', 2050, '#8FAE6B', 'The valley of the Mossback Elder, below the Burnt Hills.',
     23566449, 4117823, 11512, 2878, 0, false),
    ('the_fog', 'The Fog', 2060, '#A8A4B5', 'Low, wet ground under a fog that never lifts, where the Gloam Wisp drifts.',
     23546592, 4123004, 7195, 5756, 2, false),
    ('thornfields', 'Thornfields', 2070, '#8A8F3C', 'Thorn scrub where the Thornfield Boar charges anything that moves.',
     23566449, 4123004, 8634, 5756, 2, false)
  ) AS v(key, name, sort_order, color, lore, x, y, w, h, penalty, forest)
 CROSS JOIN (SELECT c.id FROM public.rpg_creatures c WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'place') AS top
ON CONFLICT (agency_id, key) DO NOTHING;

INSERT INTO public.rpg_creatures (agency_id, key, name, parent_id, sort_order, color, lore, place_x, place_y, place_w, place_h, place_penalty, place_forest)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, top.id, v.sort_order, v.color, v.lore, v.x, v.y, v.w, v.h, v.penalty, v.forest
  FROM (VALUES
    ('cursed_road', 'Cursed Road', 2021, '#8A6A43', 'The road from Haven through the Old Forest to the Abandoned Borderlands. Cursed roads are a haunt on the Bramblemaw card.',
     23526447, 4116966, 40290, 8, 0, false),
    ('bramblemaw_lair', 'Bramblemaw''s Lair', 2022, '#3B2F2A', 'The heart of the Old Forest, where the roots twist too tightly. The Bramblemaw card calls it its forest lair.',
     23519304, 4114152, 273, 273, 2, true)
  ) AS v(key, name, sort_order, color, lore, x, y, w, h, penalty, forest)
 CROSS JOIN (SELECT c.id FROM public.rpg_creatures c WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'old_forest') AS top
ON CONFLICT (agency_id, key) DO NOTHING;

-- The Knowing Things rule card names the roots of the knowledge tree, and the Place card is now a third one. One
-- sentence changes; the admin manual page follows by its trigger.
UPDATE public.rpg_rules
   SET body = replace(body, 'Knowing Creature and Knowing Object are the roots.', 'Knowing Creature, Knowing Object and Knowing Place are the roots.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'knowledge'
   AND position('Knowing Creature and Knowing Object are the roots.' in body) > 0;

-- The one existing function this step touches: the Creatures tab list gains one line so place cards stay off it,
-- exactly as object cards already do. Everything else in it is unchanged.
CREATE OR REPLACE FUNCTION public.rpg_creature_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Creatures tab list. Players see a card once it is shown to them; the game master also sees whether it is shown.
-- Object cards live on the Objects tab and place cards on the Maps tab, so neither is listed here.
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm)
  SELECT coalesce(jsonb_agg(
           jsonb_build_object('id', c.id, 'key', c.key, 'name', c.name, 'color', c.color, 'epigraph', c.epigraph)
           || CASE WHEN gm.is_gm THEN jsonb_build_object('shown_to_players', c.shown_to_players) ELSE '{}'::jsonb END
           ORDER BY c.sort_order, c.name), '[]'::jsonb)
  FROM public.rpg_creatures c CROSS JOIN gm
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
    AND NOT public.rpg_is_object_card(c.id)
    AND NOT public.rpg_is_place_card(c.id)
    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);
$function$;

-- Only the tab read is for logins (it checks for the game master itself); the rest is internal.
REVOKE ALL ON FUNCTION public.rpg_map_ladder() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_roll(integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_covers(double precision, double precision, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_touches(double precision, double precision, double precision, double precision, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_height(integer, double precision, double precision) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_length_text(numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_is_place_card(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_creatures_place_check() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_cells(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_view(integer, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_ladder() TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_roll(integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_covers(double precision, double precision, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_touches(double precision, double precision, double precision, double precision, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_height(integer, double precision, double precision) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_length_text(numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_is_place_card(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_cells(integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_view(integer, integer, integer) TO authenticated, service_role;

