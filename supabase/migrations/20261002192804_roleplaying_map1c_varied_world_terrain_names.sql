-- roleplaying_map1c_varied_world_terrain_names (Peter 2026-10-02 evening: "Defaults" to three calls, plus two asks).
-- 1. More variety in the land masses, like the Earth has, without looking like it: a new seed and a new way of
--    layering the rolls (three layers a grid, the first two in full), and the far north and south sink to sea.
-- 2. Unnamed land now rolls forest, hills and mountains by rule (his 2A; movement penalties 1, 1, 2).
-- 3. Continents and a home country are drafted for him to correct (his 1A). They only name the land: a place card
--    with no movement penalty has no ground of its own. The sea stays sea under every place.
-- 4. Icons on a place card are now the names of map symbols the page draws, not emoji.
-- 5. The old one-point height function is dropped (his 3A).
-- No new table and no new column. New functions: rpg_map_blend, rpg_map_ground_text, rpg_map_icons. Replaced in
-- place, same names and arguments: rpg_map_heights, rpg_map_cells, rpg_map_view, rpg_creatures_place_check.
-- The nine places move together to good land on the new world (their old spot is open sea there).

UPDATE public.rpg_settings SET value = 407
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_seed';
UPDATE public.rpg_settings SET value = 14.6, label = 'Ground at or above this height is land and below it is sea (about 29 in 100 is land, like the Earth)'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_sea_level';
UPDATE public.rpg_settings SET value = 0.6, label = 'Each layer of map rolls counts this share of the layer before it, once the full layers are past'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_detail_share';
INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_full_layers', 2, 'The first this-many layers of map rolls count in full, so the world has several big land masses and not one'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_pole_pull', 80, 'Height taken off the ground at the very top and bottom edge of the map, fading fast toward the middle, so no land is cut off by the edge'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_mountain_band', 6.1, 'Unnamed land is mountains where its ground roll is within this of the middle (about 7 in 100 of the land)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_hills_band', 15.8, 'Unnamed land is hills where its ground roll is within this of the middle, outside the mountains (about 11 in 100 of the land)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_forest_level', 31.2, 'Unnamed land is forest where its ground roll is at or above this (about 27 in 100 of the land)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_forest_penalty', 1, 'Movement penalty of unnamed forest: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_hills_penalty', 1, 'Movement penalty of unnamed hills: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_mountain_penalty', 2, 'Movement penalty of unnamed mountains: a square costs 1 plus this')
ON CONFLICT (agency_id, key) DO NOTHING;

COMMENT ON COLUMN public.rpg_creatures.place_penalty IS 'Place cards only: the movement penalty of its ground, 0 to 9, read the way a fight board square is (rpg_square_info). Empty = the place only names the land (a continent, a country): the ground under it stays what the map rule or a smaller place makes it.';
COMMENT ON COLUMN public.rpg_creatures.place_icon IS 'Place cards only: the map symbol drawn for it, by name (rpg_map_icons: forest, hills, mountains, village, road, lair, ruins, valley, fog, thorns). None = its color alone.';

CREATE OR REPLACE FUNCTION public.rpg_map_icons()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $fn$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here.
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns'];
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_ground_text(p_forest boolean, p_penalty integer)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
-- A ground in words, the same for a place card and for unnamed ground: forest or not, and its movement penalty
-- (a square costs 1 plus the penalty). Forest at penalty 1 reads "forest · movement penalty 1"; neither reads
-- "open ground".
SELECT coalesce(nullif(concat_ws(' · ', CASE WHEN p_forest THEN 'forest' END,
                                 CASE WHEN p_penalty > 0 THEN 'movement penalty ' || p_penalty::text END), ''), 'open ground');
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_creatures_place_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A place is a card under the Place card, and only a place has a spot on the world map. A place needs a center
-- (place_x, place_y, in world squares from the north-west corner) on the world, a size (place_w, place_h, in
-- squares) of 1 square up to the whole world, and a level (place_level): the kind of place it is, named by the grid
-- of the map ladder that is about it, 2 a continent, 3 a country, 4 a region, 5 a city, 6 a district, 7 a battle
-- grid.
-- Ground: a place with a movement penalty (0 to 9) is ground of its own, forest or not (not, when not given): the
-- Old Forest is forest at penalty 1. A place with no movement penalty only names the land, the way a continent or
-- a country does: the ground under it stays what the map rule or a smaller place makes it, and it is not forest or
-- open either.
-- It may carry an icon (place_icon): the name of a map symbol the page can draw (rpg_map_icons).
-- A place made from another place sits inside it and is no bigger a kind of place: the Cursed Road has its center
-- in the Old Forest, and a country is never made from a city. The Place card itself and every card that is not a
-- place carry none of these.
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
  NEW.place_icon := nullif(btrim(NEW.place_icon), '');
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  IF NEW.place_x NOT BETWEEN 0 AND v_world - 1 OR NEW.place_y NOT BETWEEN 0 AND v_world / 2 - 1 THEN
    RAISE EXCEPTION '%: its center is off the world', NEW.name;
  END IF;
  IF NEW.place_w NOT BETWEEN 1 AND v_world OR NEW.place_h NOT BETWEEN 1 AND v_world / 2 THEN
    RAISE EXCEPTION '%: a place is at least 1 square and no bigger than the world', NEW.name;
  END IF;
  IF NEW.place_penalty IS NULL THEN
    IF NEW.place_forest IS NOT NULL THEN
      RAISE EXCEPTION '% has no movement penalty, so it only names the land: leave forest empty too, or give it a movement penalty (0 is open ground)', NEW.name;
    END IF;
  ELSE
    NEW.place_forest := coalesce(NEW.place_forest, false);
    IF NEW.place_penalty NOT BETWEEN 0 AND 9 THEN
      RAISE EXCEPTION '%: a movement penalty is 0 to 9', NEW.name;
    END IF;
  END IF;
  IF NEW.place_level IS NULL OR NEW.place_level NOT BETWEEN 2 AND v_last THEN
    RAISE EXCEPTION '% is a place, so it needs a level: %', NEW.name,
      (SELECT string_agg(l.level::text || ' a ' || lower(l.name), ', ' ORDER BY l.level) FROM public.rpg_map_ladder() l WHERE l.level > 1);
  END IF;
  IF NEW.place_icon IS NOT NULL AND NOT (NEW.place_icon = ANY (public.rpg_map_icons())) THEN
    RAISE EXCEPTION '%: "%" is not a map symbol. The symbols are: %', NEW.name, NEW.place_icon, array_to_string(public.rpg_map_icons(), ', ');
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

-- The nine places move together, 6 Continent-grid cells west and 25 south, onto good land on the new world: open
-- country between a forest and hills (country grid 3-88-41). Their layout inside the country grid is unchanged.
-- Their icons become the names of map symbols. Parents first, then the two places made from the Old Forest.
UPDATE public.rpg_creatures c
   SET place_x = c.place_x - 1492992, place_y = c.place_y + 6220800, place_icon = v.icon
  FROM (VALUES ('haven', 'village'), ('old_forest', 'forest'), ('abandoned_borderlands', 'ruins'), ('burnt_hills', 'hills'),
               ('mossback_valley', 'valley'), ('the_fog', 'fog'), ('thornfields', 'thorns')) AS v(key, icon)
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = v.key AND c.place_x BETWEEN 23400000 AND 23600000;

UPDATE public.rpg_creatures c
   SET place_x = c.place_x - 1492992, place_y = c.place_y + 6220800, place_icon = v.icon
  FROM (VALUES ('cursed_road', 'road'), ('bramblemaw_lair', 'lair')) AS v(key, icon)
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = v.key AND c.place_x BETWEEN 23400000 AND 23600000;

-- Six continents and a home country, drafted for Peter to correct (names, middles, sizes). Each is the oval that
-- sits inside one land mass of the new world, so its name lands on that land. They only name the land: no movement
-- penalty, so the ground under them stays forest, hills, mountains or open as the map rule gives it.
INSERT INTO public.rpg_creatures (agency_id, key, name, parent_id, sort_order, color, lore, place_x, place_y, place_w, place_h, place_level)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, top.id, v.sort_order, v.color, v.lore, v.x, v.y, v.w, v.h, 2
  FROM (VALUES
    ('westerwold', 'Westerwold', 2001, '#B08D57', 'The largest land in the world: wide open country north of a long mountain wall, a forest shore in the south and a great forest in the east.',
     7216128, 8833536, 12690432, 13747968),
    ('southmere', 'Southmere', 2002, '#6F8FAF', 'A southern land: forest in the north, a mountain wall across its middle and open country below it.',
     15178752, 12192768, 5076173, 8460288),
    ('dawnmoor', 'Dawnmoor', 2003, '#C97B63', 'The land where Haven lies: forest in the west, open country in the middle, hills and mountains to the east and south.',
     23639040, 9455616, 6768230, 5499187),
    ('windrun', 'Windrun', 2004, '#D9C27A', 'A northern land of open country from shore to shore.',
     30357504, 4727808, 5499187, 5499187),
    ('farwatch', 'Farwatch', 2005, '#8C8C9E', 'A big island off the north shore of Westerwold: open country with a few hills.',
     6967296, 5101056, 3807130, 3172608),
    ('greenmantle', 'Greenmantle', 2006, '#5E8C5A', 'A far southern land that is mostly forest.',
     26127360, 15303168, 3384115, 3172608)
  ) AS v(key, name, sort_order, color, lore, x, y, w, h)
 CROSS JOIN (SELECT c.id FROM public.rpg_creatures c WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'place') AS top
ON CONFLICT (agency_id, key) DO NOTHING;

INSERT INTO public.rpg_creatures (agency_id, key, name, parent_id, sort_order, color, lore, place_x, place_y, place_w, place_h, place_level)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'havenmark', 'Havenmark', top.id, 2008, '#A8743A',
       'The country around Haven, between the western forest and the eastern hills.', 22021632, 10326528, 1007261, 719472, 3
  FROM (SELECT c.id FROM public.rpg_creatures c WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'dawnmoor') AS top
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_blend(p_part integer, p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The layered rolls of the world map, read at the center of every cell in a block of cells of one grid. The one
-- home of how the map's fixed-seed rolls (rpg_map_roll) are layered and blended; worked out when asked and never
-- stored. p_part picks the set of rolls: 0 is the height of the ground (rpg_map_heights), 1 is the kind of ground
-- (rpg_map_cells: mountains, hills, forest). Part p uses roll layers p x 100 + 1 and up.
-- Every grid from the world down to p_level adds three layers. The world grid rolls on points 3 cells apart, 2
-- cells apart and on every cell; every grid below it rolls on points 6 cells apart, 3 apart and on every cell. So
-- each layer's points are 2 or 3 times closer than the layer before, from a quarter of the way round the world
-- down to one square. A layer is read by blending the four rolls around the cell center, and a roll counts as its
-- number less 50.5.
-- The first map_full_layers layers (2) count in full; each layer after counts map_detail_share (0.6) of the one
-- before: 1, 1, 0.6, 0.36, 0.216 and so on. Rolls of 80 and 30 on the first two layers alone give 29.5 - 20.5 = 9.
-- So the coarse layers set where the land masses are and each layer down adds finer shape.
-- A whole block is one call so that every roll is made once (rl) and shared by all the cells around it. The rolls
-- stay in one list outside the joins. What a layer adds at a cell is rounded to a whole number of 2^30ths (about a
-- billionth), so the layers add up to exactly the same number in whatever order they are added. The map wraps
-- east to west; north and south it stops at the edge.
WITH RECURSIVE cfg AS (
       SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers,
              (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level) AS cell),
     wt(n, w) AS (
       -- What each layer counts, by multiplying one layer at a time so the numbers are the same on any machine.
       SELECT 1, 1::double precision
       UNION ALL
       SELECT wt.n + 1, CASE WHEN wt.n + 1 > cfg.full_layers THEN wt.w * cfg.share ELSE wt.w END
         FROM wt CROSS JOIN cfg
        WHERE wt.n < 3 * p_level),
     lay AS MATERIALIZED (
       -- One row a layer, coarsest first. n = its number; f = cells of this grid from one of its points to the
       -- next; nx, ny = its points around and down the world; wt = what it counts; a_lo, b_lo = the first point
       -- the block needs; wd, ht = points across and down the block; off = the rolls of the layers before it.
       SELECT q.n, q.f, q.nx, q.ny, wt.w AS wt, q.a_lo, q.b_lo, q.wd, q.ht,
              (sum(q.wd * q.ht) OVER (ORDER BY q.n) - q.wd * q.ht)::integer AS off
         FROM (SELECT (l.level - 1) * 3 + v.i AS n, k.f, l.across / k.m AS nx, l.down / k.m AS ny,
                      floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer AS a_lo,
                      floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer AS b_lo,
                      floor((p_x0 + p_cols - 0.5::double precision) / k.f - 0.5)::integer - floor((p_x0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS wd,
                      floor((p_y0 + p_rows - 0.5::double precision) / k.f - 0.5)::integer - floor((p_y0 + 0.5::double precision) / k.f - 0.5)::integer + 2 AS ht
                 FROM cfg CROSS JOIN public.rpg_map_ladder() l CROSS JOIN (VALUES (1, 3, 6), (2, 2, 3), (3, 1, 1)) AS v(i, world_gap, below_gap)
                CROSS JOIN LATERAL (SELECT CASE WHEN l.level = 1 THEN v.world_gap ELSE v.below_gap END AS m) g
                CROSS JOIN LATERAL (SELECT g.m, g.m * (l.cell / cfg.cell) AS f) k
                WHERE l.level <= p_level) q
         JOIN wt ON wt.n = q.n),
     rl AS MATERIALIZED (
       -- Every roll the block needs, made once and kept in one list: layer by layer, each layer row by row.
       SELECT ARRAY(SELECT public.rpg_map_roll(cfg.seed, p_part * 100 + l.n, mod(mod(l.a_lo + i, l.nx) + l.nx, l.nx), least(greatest(l.b_lo + j, 0), l.ny - 1))
                      FROM cfg CROSS JOIN lay l CROSS JOIN LATERAL generate_series(0, l.ht - 1) AS j CROSS JOIN LATERAL generate_series(0, l.wd - 1) AS i
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
        CROSS JOIN LATERAL (SELECT floor(v.v)::integer AS b) b)
-- One row a cell: the sum over the layers of what each adds at the cell, from the four rolls around it.
SELECT ax.gx, ay.gy,
       sum(floor(l.wt * (((SELECT rl.rolls FROM rl)[ay.j + ax.i + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + 2] * ax.sx) * (1 - ay.sy)
                       + ((SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 1] * (1 - ax.sx) + (SELECT rl.rolls FROM rl)[ay.j + ax.i + l.wd + 2] * ax.sx) * ay.sy - 50.5)
                 * 1073741824 + 0.5) / 1073741824)
  FROM lay l
  JOIN ax ON ax.n = l.n
  JOIN ay ON ay.n = l.n
 GROUP BY ax.gx, ay.gy;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_heights(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, height double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- How high the ground stands at the center of every cell in a block of cells of one grid of the world map. Land
-- where the height is at or above the sea level (rpg_settings map_sea_level, 14.6), sea below it. The one home of
-- land and sea, worked out when asked and never stored.
-- The height is the height rolls of the map (rpg_map_blend, part 0) less a pull toward the sea at the far north and
-- south, so no land is cut off by the top or bottom edge of the map: map_pole_pull (80) x how far the cell is from
-- the middle line toward the edge (0 to 1), raised to the eighth power. Halfway to the edge that is 80 x 0.5^8 =
-- 0.3; nine tenths of the way it is 80 x 0.9^8 = 34.
SELECT b.x, b.y, b.value - c.pole * ((e.e2 * e.e2) * (e.e2 * e.e2))
  FROM public.rpg_map_blend(0, p_level, p_x0, p_y0, p_cols, p_rows) b
 CROSS JOIN (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_pole_pull')::double precision AS pole,
                    (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = p_level) AS down) c
 CROSS JOIN LATERAL (SELECT abs(2 * (b.y + 0.5::double precision) / c.down - 1) AS e1) d
 CROSS JOIN LATERAL (SELECT d.e1 * d.e1 AS e2) e;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The ground of any block of cells of any grid of the world map, worked out when asked and never stored. The one
-- home of what a cell is; a single square under a piece is the same call at the battle grid, 1 by 1.
-- x, y = the cell, counted across the whole world at that level. p_x0, p_y0 = the first cell of the block.
-- kind, in this order:
--   sea        its height (rpg_map_heights) is below the sea level. The sea stays sea under every place.
--   place      a place card with ground of its own (a movement penalty) covers its center; place_id = the
--              smallest such card. A place fills a cell of a grid when it covers the center of the cell its own
--              center falls in; only places that fill are ground.
--   mountains  unnamed land whose ground roll (rpg_map_blend, part 1) is within map_mountain_band (6.1) of the
--              middle: mountains run in chains along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- A place with no movement penalty (a continent, a country) only names the land and never changes a cell.
-- marks = the places with ground that reach into a land cell but are too small or too thin to fill any cell of
-- this grid, smallest first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this
-- grid is about are marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is
-- not marked on a Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest),
     pl AS MATERIALIZED (
       SELECT q.id, q.place_x, q.place_y, q.place_w, q.place_h, q.area, q.fills
         FROM (SELECT c.id, c.place_x, c.place_y, c.place_w, c.place_h, c.place_level, c.place_w::bigint * c.place_h AS area,
                      public.rpg_map_covers(((c.place_x / lad.cell + 0.5) * lad.cell)::double precision, ((c.place_y / lad.cell + 0.5) * lad.cell)::double precision,
                                            c.place_x, c.place_y, c.place_w, c.place_h, lad.world) AS fills
                 FROM public.rpg_creatures c CROSS JOIN lad
                WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
                  AND c.place_penalty IS NOT NULL
                  AND public.rpg_map_touches(p_x0::double precision * lad.cell, p_y0::double precision * lad.cell,
                                             (p_x0 + p_cols)::double precision * lad.cell, (p_y0 + p_rows)::double precision * lad.cell,
                                             c.place_x, c.place_y, c.place_w, c.place_h, lad.world)) q
        WHERE q.fills OR q.place_level <= p_level + 1),
     g AS MATERIALIZED (
       SELECT h.x AS gx, h.y AS gy, h.height >= cfg.sea AS dry, r.value AS ground, lad.cell, lad.world,
              ((h.x + 0.5) * lad.cell)::double precision AS cx, ((h.y + 0.5) * lad.cell)::double precision AS cy
         FROM lad CROSS JOIN cfg
        CROSS JOIN public.rpg_map_heights(p_level, p_x0, p_y0, p_cols, p_rows) h
         JOIN public.rpg_map_blend(1, p_level, p_x0, p_y0, p_cols, p_rows) r ON r.x = h.x AND r.y = h.y)
SELECT g.gx, g.gy,
       CASE WHEN NOT g.dry THEN 'sea'
            WHEN count(*) FILTER (WHERE p.fills) > 0 THEN 'place'
            WHEN abs(g.ground) < (SELECT cfg.mountains FROM cfg) THEN 'mountains'
            WHEN abs(g.ground) < (SELECT cfg.hills FROM cfg) THEN 'hills'
            WHEN g.ground >= (SELECT cfg.forest FROM cfg) THEN 'forest'
            ELSE 'land' END,
       (array_agg(p.id ORDER BY p.area, p.id) FILTER (WHERE p.fills))[1],
       coalesce(array_agg(p.id ORDER BY p.area, p.id) FILTER (WHERE NOT p.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN pl p
    ON g.dry
   AND CASE WHEN p.fills
            THEN public.rpg_map_covers(g.cx, g.cy, p.place_x, p.place_y, p.place_w, p.place_h, g.world)
            ELSE public.rpg_map_touches(g.gx::double precision * g.cell, g.gy::double precision * g.cell,
                                        (g.gx + 1)::double precision * g.cell, (g.gy + 1)::double precision * g.cell,
                                        p.place_x, p.place_y, p.place_w, p.place_h, g.world) END
 GROUP BY g.gx, g.gy, g.dry, g.ground
 ORDER BY g.gy, g.gx;
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- The Maps tab in one read, game master only: one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). p_level 1 is the world; a deeper grid is named by its level and by the cell of the grid
-- above that it fills, counted across the whole world: 3, 88, 41 is the Country grid inside cell 88, 41 of the
-- Continent grids.
-- Returns the grid (level, name, title, cols, rows, scale), the way back up (crumbs), the grid next door each way
-- (moves), every cell in reading order (x, y, its name like C5, kind sea / land / forest / hills / mountains /
-- place, place = the card it belongs to, marks = other place cards reaching into it, open = the grid inside it),
-- every place card (name, color, icon = the name of its map symbol, size, ground = its ground in words or nothing
-- when it only names the land, the place it is inside, level = the kind of place it is, view = the grid of its own
-- level around its center, listed = it belongs on this grid's list, spot = where to write its name on this grid:
-- its center from the top-left corner, then its width and height, all four in thousandths of a cell, or nothing
-- when the center is off the grid), list = what this grid lists, the places one level down that reach into it
-- (the world lists continents, a continent countries, a country regions, a region cities, a city districts, a
-- district battle grids; a battle grid lists nothing), within = the continent, country and so on that hold the
-- middle of this grid, biggest first (only places that name the land, the smallest of each kind), grounds = each
-- kind of unnamed ground with its name and, when it has one, its movement penalty in words, and the ladder of
-- grids in words.
-- The world also carries detail: every cell of the Continent grids inside it, 144 across and 72 down, one
-- character a cell (~ sea, . open land, t forest, h hills, m mountains, else the character numbered 256 + the
-- place's spot in detail.places, counted from 0), so the world is drawn as fine as the grids inside it.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := coalesce(p_x, 0);
  v_y         integer := coalesce(p_y, 0);
  v_x0        integer := 0;
  v_y0        integer := 0;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
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
  v_within    jsonb;
  v_grounds   jsonb;
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
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_l.cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_l.rows)::bigint * v_l.cell;

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
         ln AS (SELECT d.y, string_agg(CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.' WHEN 'forest' THEN 't'
                                                   WHEN 'hills' THEN 'h' WHEN 'mountains' THEN 'm'
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
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_ground_text(c.place_forest, c.place_penalty) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', c.lore,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text,
           'listed', c.place_level = v_l.level + 1
                     AND public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                c.place_x, c.place_y, c.place_w, c.place_h, v_world),
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
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;

  SELECT coalesce(jsonb_agg(q.name ORDER BY q.place_level), '[]'::jsonb)
    INTO v_within
    FROM (SELECT DISTINCT ON (c.place_level) c.place_level, c.name
            FROM public.rpg_creatures c
           WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
             AND c.place_penalty IS NULL AND c.place_level <= v_l.level
             AND public.rpg_map_covers((v_gx0 + v_gx1) / 2.0::double precision, (v_gy0 + v_gy1) / 2.0::double precision,
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1) q;

  SELECT jsonb_strip_nulls(jsonb_build_object(
           'sea', jsonb_build_object('name', 'Sea'),
           'land', jsonb_build_object('name', 'Open land'),
           'forest', jsonb_build_object('name', 'Forest', 'penalty', CASE WHEN g.forest > 0 THEN public.rpg_map_ground_text(false, g.forest) END),
           'hills', jsonb_build_object('name', 'Hills', 'penalty', CASE WHEN g.hills > 0 THEN public.rpg_map_ground_text(false, g.hills) END),
           'mountains', jsonb_build_object('name', 'Mountains', 'penalty', CASE WHEN g.mountains > 0 THEN public.rpg_map_ground_text(false, g.mountains) END)))
    INTO v_grounds
    FROM (SELECT (max(s.value) FILTER (WHERE s.key = 'map_forest_penalty'))::integer AS forest,
                 (max(s.value) FILTER (WHERE s.key = 'map_hills_penalty'))::integer AS hills,
                 (max(s.value) FILTER (WHERE s.key = 'map_mountain_penalty'))::integer AS mountains
            FROM public.rpg_settings s
           WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_forest_penalty', 'map_hills_penalty', 'map_mountain_penalty')) g;

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
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $fn$;

-- The one-point height function from step 1: nothing calls it since this afternoon, and its math is the old world.
-- Peter said to remove it (2026-10-02, call 3A).
DROP FUNCTION IF EXISTS public.rpg_map_height(integer, double precision, double precision);

-- The new functions are internal, like the rest of the map functions; only rpg_map_view is for logins.
REVOKE ALL ON FUNCTION public.rpg_map_blend(integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_ground_text(boolean, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_icons() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_blend(integer, integer, integer, integer, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_ground_text(boolean, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_icons() TO service_role;

