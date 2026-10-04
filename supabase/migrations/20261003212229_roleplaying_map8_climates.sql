-- Roleplaying world map, corrections step 5 (Peter 2026-10-03, 21:03: "1c. 2c, but change mountains and forest to
-- match"): climates. Seven new grounds by the climate of a spot: snow and ice and tundra toward the poles, pine forest
-- in the cold, desert and grassy plains where it is dry, jungle where it is hot and wet, swamp in wet lowlands (1C).
-- Movement penalties (2C, forest and mountains raised to match): open land and grassy plains 0; hills and tundra 1;
-- forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3. Pine forest and jungle are forest (they
-- burn and hide like forest).
-- New: rpg_map_grounds (the one list of grounds: name, letter on a grid drawn fine, penalty setting, forest),
-- rpg_map_climate (the one home of the climate rule). Changed in place: rpg_map_cells (the climate after the woods,
-- clearings and rough ground), rpg_map_ground (reads rpg_map_grounds), rpg_map_view_block (letters and the key from
-- rpg_map_grounds), rpg_map_icons (the new grounds are symbols too), rpg_fight_squares (comment only). Settings: seven
-- new penalties, the climate cut-offs, forest 1 -> 2 and mountains 2 -> 3. Rule cards world_map and moving: the
-- costs and the climates. No table or column changes, no drops.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_pine_penalty', 2, 'Movement penalty of pine forest: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_jungle_penalty', 2, 'Movement penalty of jungle: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_desert_penalty', 2, 'Movement penalty of desert: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_tundra_penalty', 1, 'Movement penalty of tundra: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_ice_penalty', 3, 'Movement penalty of snow and ice: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_swamp_penalty', 3, 'Movement penalty of swamp: a square costs 1 plus this'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_climate_fine', 248832, 'The climate of a spot is read from the map rolls down to points this many squares apart (248,832 is one Continent cell, 173 miles), so a spot has the same climate at every zoom'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_warmth_share', 0.35, 'Warmth runs from 100 at the equator to 0 at the poles, plus this share of the warmth roll (about 30 either way, so about 10 warmer or colder)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_wet_band', 24, 'Wetness is the wetness roll (about 30 either way) plus up to this much by latitude: wettest at the equator and two thirds of the way to a pole, driest a third of the way and at the poles'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_ice_warmth', 18, 'Land colder than this is snow and ice (mountains stay mountains)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_tundra_warmth', 28, 'Land colder than this is tundra (hills stay hills)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_cold_warmth', 42, 'Land colder than this is the cold belt: its forest is pine forest, and so is its wetter open land; its driest land is grassy plains'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_taiga_wet', 0, 'In the cold belt, open land at least this wet is pine forest too'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_hot_warmth', 70, 'Land at least this warm is hot: where it is also wet enough, it is jungle'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_jungle_wet', 12, 'Hot land at least this wet is jungle'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_desert_wet', -35, 'Land drier than this, outside the cold belt, is desert'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_plains_wet', -20, 'Land drier than this that is not desert is grassy plains, forest too'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_swamp_wet', 30, 'Land at least this wet and low enough, outside snow, ice and tundra, is swamp'),
  ('126794dd-25ff-47d2-a436-724499733365', 'map_swamp_height', 3, 'Wet land no higher than this above the sea is swamp (land stands 0 to about 40 above the sea)')
ON CONFLICT (agency_id, key) DO NOTHING;

-- Peter 2026-10-03 21:03: forest and mountains raised to match the harsher climate costs.
UPDATE public.rpg_settings SET value = 2 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_forest_penalty';
UPDATE public.rpg_settings SET value = 3 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_mountain_penalty';

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates), in the order
-- the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block detail; the page reads
-- the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds its movement penalty (rpg_map_ground;
-- none = penalty 0; the sea = no entry), and whether it is forest (it has trees: it burns and hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', NULL, false),
               (3, 'plains', 'Grassy plains', 'g', NULL, false),
               (4, 'forest', 'Forest', 't', 'map_forest_penalty', true),
               (5, 'pine', 'Pine forest', 'p', 'map_pine_penalty', true),
               (6, 'jungle', 'Jungle', 'j', 'map_jungle_penalty', true),
               (7, 'hills', 'Hills', 'h', 'map_hills_penalty', false),
               (8, 'mountains', 'Mountains', 'm', 'map_mountain_penalty', false),
               (9, 'desert', 'Desert', 'd', 'map_desert_penalty', false),
               (10, 'tundra', 'Tundra', 'u', 'map_tundra_penalty', false),
               (11, 'ice', 'Snow and ice', 'i', 'map_ice_penalty', false),
               (12, 'swamp', 'Swamp', 's', 'map_swamp_penalty', false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_ground(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(penalty integer, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What a cell of the world map costs to walk into, by its kind (rpg_map_cells): the one home of the movement
-- penalty of the map. A square costs 1 plus its penalty. Unnamed ground reads its penalty from the setting
-- rpg_map_grounds names for it (open land and grassy plains have none, so 0; Peter 2026-10-03: hills and tundra 1;
-- forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3, so a mountain square costs 4) and is
-- forest when it has trees; a place reads the penalty and forest on its card. The sea has no penalty because nobody
-- walks into it (Peter 2026-10-03, 2A).
SELECT CASE WHEN p_kind = 'place' THEN (SELECT c.place_penalty FROM public.rpg_creatures c WHERE c.id = p_place)
            WHEN g.kind IS NULL OR g.kind = 'sea' THEN NULL
            WHEN g.penalty_key IS NULL THEN 0
            ELSE (SELECT s.value::integer FROM public.rpg_settings s
                   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = g.penalty_key) END,
       CASE WHEN p_kind = 'place' THEN coalesce((SELECT c.place_forest FROM public.rpg_creatures c WHERE c.id = p_place), false)
            ELSE coalesce(g.forest, false) END
  FROM (SELECT 1) AS one
  LEFT JOIN public.rpg_map_grounds() g ON g.kind = p_kind;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climate(p_kind text, p_warmth double precision, p_wet double precision, p_height double precision,
                                                  p_ice double precision, p_tundra double precision, p_cold double precision, p_hot double precision,
                                                  p_desert double precision, p_plains double precision, p_jungle double precision, p_taiga double precision,
                                                  p_swamp_wet double precision, p_swamp_height double precision)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What the climate of a spot makes of its ground (Peter 2026-10-03: more climates, like desert and tundra), the one
-- home of the climate rule. p_kind = the ground before climate (rpg_map_cells: open land, forest, hills or mountains,
-- after the woods, clearings and rough ground); p_warmth = 100 at the equator down to 0 at the poles, moved by the
-- warmth rolls; p_wet = the wetness rolls moved by latitude; p_height = how far it stands above the sea. The cut-offs
-- are the settings rpg_map_cells reads (map_ice_warmth and the rest). In this order:
--   snow and ice   colder than p_ice (18): open land, forest and hills; mountains stay mountains
--   hills          stay hills everywhere else (rough or rocky ground in every climate)
--   tundra         colder than p_tundra (28)
--   swamp          at least p_swamp_wet (30) wet and no higher than p_swamp_height (3) above the sea
--   the cold belt  colder than p_cold (42): forest is pine forest, and so is open land at least p_taiga (0) wet; open
--                  land drier than p_desert (-35) is grassy plains; other open land stays open land
--   desert         drier than p_desert (-35)
--   grassy plains  drier than p_plains (-20), forest too
--   jungle         at least p_hot (70) warm and at least p_jungle (12) wet
--   else the ground stays as it was. The sea and a place's own ground never change.
-- A spot 10 degrees from the equator (warmth about 89) with a wetness of 20 is jungle; one 30 degrees out (warmth
-- about 67) with a wetness of -40 is desert.
SELECT CASE
         WHEN p_kind IS NULL OR p_kind NOT IN ('land', 'forest', 'hills') THEN p_kind
         WHEN p_warmth < p_ice THEN 'ice'
         WHEN p_kind = 'hills' THEN 'hills'
         WHEN p_warmth < p_tundra THEN 'tundra'
         WHEN p_wet >= p_swamp_wet AND p_height <= p_swamp_height THEN 'swamp'
         WHEN p_warmth < p_cold THEN CASE WHEN p_kind = 'forest' OR p_wet >= p_taiga THEN 'pine'
                                          WHEN p_wet < p_desert THEN 'plains' ELSE 'land' END
         WHEN p_wet < p_desert THEN 'desert'
         WHEN p_wet < p_plains THEN 'plains'
         WHEN p_warmth >= p_hot AND p_wet >= p_jungle THEN 'jungle'
         ELSE p_kind END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_icons()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $fn$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp) are symbols too.
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp'];
$fn$;

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
--   place      its center lies inside a place card with ground of its own (a movement penalty), by the natural
--              edge of that place (rpg_map_within); place_id = the smallest such card. A place fills cells of a
--              grid when its oval covers the center of the cell its own center falls in; only places that fill
--              are ground.
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
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swamp_height')::double precision AS swamp_height),
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
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind
 ORDER BY g.gy, g.gx;
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
-- the world, the Continent grids: 144 across and 72 down), one character a cell (the letter of its ground in
-- rpg_map_grounds: ~ sea, . open land, t forest and so on; else the character numbered 256 + the place's spot in
-- detail.places, counted from 0), so they
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
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id))
                                            ELSE g.ch END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                  LEFT JOIN public.rpg_map_grounds() g ON g.kind = d.kind
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

  SELECT jsonb_object_agg(g.kind, jsonb_strip_nulls(jsonb_build_object(
           'name', g.name, 'penalty', CASE WHEN r.penalty > 0 THEN public.rpg_map_ground_text(false, r.penalty) END)))
    INTO v_grounds
    FROM public.rpg_map_grounds() g
   CROSS JOIN LATERAL public.rpg_map_ground(g.kind) r;

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

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_cells on the battle
-- grid, its penalty and forest from rpg_map_ground; the sea no entry), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.place_id
                          FROM s CROSS JOIN LATERAL public.rpg_map_cells(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map)
SELECT g.x, g.y,
       CASE WHEN m.kind = 'sea' THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(r.penalty, i.penalty) END,
       coalesce(r.forest, false) OR i.forest, i.burning, coalesce(m.kind = 'sea', false)
  FROM s CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
  LEFT JOIN LATERAL public.rpg_map_ground(m.kind, m.place_id) r ON true
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

UPDATE public.rpg_rules
   SET body = replace(replace(body,
         'Open land has penalty 0, forest 1, hills 1 and mountains 2.',
         'Open land and grassy plains have penalty 0; hills and tundra 1; forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3. The climate shapes the land: snow and ice, then tundra, toward the poles; pine forest in the cold; desert and grassy plains where it is dry; jungle where it is hot and wet; swamp in wet lowlands.'),
         'Mountains cost 3 a square, so a mile of them takes 1 hour at Speed 10.',
         'Mountains cost 4 a square, so a mile of them takes 1 hour 20 minutes at Speed 10.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map';

UPDATE public.rpg_rules
   SET body = replace(replace(body,
         'from the map: open land 0, forest 1, hills 1, mountains 2.',
         'from the map: open land and grassy plains 0; hills and tundra 1; forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3.'),
         'Forest is wherever the map has forest.',
         'Forest is wherever the map has forest, pine forest or jungle.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving';

REVOKE ALL ON FUNCTION public.rpg_map_grounds() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_climate(text, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_grounds() TO service_role;
GRANT EXECUTE ON FUNCTION public.rpg_map_climate(text, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision) TO service_role;

