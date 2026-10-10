INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
('126794dd-25ff-47d2-a436-724499733365', 'map_savanna_penalty', 5, 'Savanna and scrub: least percent of time a square adds to cross it (open grass; light brush 1.2 times firm ground, Soule and Goldman 1972)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_savanna_penalty_high', 50, 'Savanna and scrub: most percent of time a square adds to cross it (thorn scrub; heavy brush 1.5, Soule and Goldman 1972)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_dunes_penalty', 80, 'Sand dunes: least percent of time a square adds to cross it (loose sand 2.1 times firm ground, Soule and Goldman 1972)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_dunes_penalty_high', 150, 'Sand dunes: most percent of time a square adds to cross it (loose sand up a dune face)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_salt_penalty', 0, 'Salt flats: least percent of time a square adds to cross it (a hard flat crust, like a dirt road)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_salt_penalty_high', 15, 'Salt flats: most percent of time a square adds to cross it (where the crust breaks into mud)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_bog_penalty', 50, 'Bog: least percent of time a square adds to cross it (firm peat and heather)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_bog_penalty_high', 150, 'Bog: most percent of time a square adds to cross it (wet peat; swampy bog 1.8 times firm ground, Soule and Goldman 1972)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_savanna_warmth', 60, 'Savanna and scrub: open land at least this warm (100 at the equator, 0 at the poles)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_savanna_wet', 10, 'Savanna and scrub: open land drier than this (wetter is open land or jungle)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_dunes_wet', -57, 'Sand dunes: desert drier than this (about a quarter of desert is sand sea)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_salt_height', 1, 'Salt flats: desert no higher than this above the sea (dry lake beds and coastal sabkha)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_settle_savanna', 1, 'How well savanna and scrub is settled (open land 1): as well as the open land it was, so no village moves'),
('126794dd-25ff-47d2-a436-724499733365', 'map_settle_dunes', 0.01, 'How well sand dunes are settled (open land 1)'),
('126794dd-25ff-47d2-a436-724499733365', 'map_settle_salt', 0, 'How well salt flats are settled (open land 1): nobody lives on them'),
('126794dd-25ff-47d2-a436-724499733365', 'map_settle_bog', 0.1, 'How well bog is settled (open land 1)')
ON CONFLICT (agency_id, key) DO NOTHING;
CREATE OR REPLACE FUNCTION public.rpg_map_climate(p_kind text, p_warmth double precision, p_wet double precision, p_height double precision, p_ice double precision, p_tundra double precision, p_cold double precision, p_hot double precision, p_desert double precision, p_plains double precision, p_jungle double precision, p_taiga double precision, p_swamp_wet double precision, p_swamp_height double precision, p_savanna_warmth double precision, p_savanna_wet double precision, p_dunes_wet double precision, p_salt_height double precision)
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
--   swamp          at least p_swamp_wet (30) wet and no higher than p_swamp_height (3) above the sea; bog where that
--                  wet lowland is in the cold belt, colder than p_cold (42): peat bog is the wetland of cool lands (more
--                  terrain step 1, Peter 2026-10-10)
--   the cold belt  colder than p_cold (42): forest is pine forest, and so is open land at least p_taiga (0) wet; open
--                  land drier than p_desert (-35) is grassy plains; other open land stays open land
--   desert         drier than p_desert (-35): salt flats where it lies no higher than p_salt_height (1) above the sea
--                  (dry lake beds and coastal sabkha, the lowest desert ground), sand dunes where it is drier than
--                  p_dunes_wet (-57: about a quarter of desert is sand sea, the rest rock and gravel)
--   grassy plains  drier than p_plains (-20), forest too (in the warm belt, the dry grassland next to the desert)
--   savanna        other open land at least p_savanna_warmth (60) warm and drier than p_savanna_wet (10): grass with
--                  scattered trees and thorn scrub, the warm belt between the dry grassland and the jungle (Whittaker
--                  biomes); forest there stays forest
--   jungle         at least p_hot (70) warm and at least p_jungle (12) wet
--   else the ground stays as it was. The sea and a place's own ground never change.
-- A spot 10 degrees from the equator (warmth about 89) with a wetness of 20 is jungle; one 30 degrees out (warmth
-- about 67) with a wetness of -40 is desert.
SELECT CASE
         WHEN p_kind IS NULL OR p_kind NOT IN ('land', 'forest', 'hills') THEN p_kind
         WHEN p_warmth < p_ice THEN 'ice'
         WHEN p_kind = 'hills' THEN 'hills'
         WHEN p_warmth < p_tundra THEN 'tundra'
         WHEN p_wet >= p_swamp_wet AND p_height <= p_swamp_height THEN CASE WHEN p_warmth < p_cold THEN 'bog' ELSE 'swamp' END
         WHEN p_warmth < p_cold THEN CASE WHEN p_kind = 'forest' OR p_wet >= p_taiga THEN 'pine'
                                          WHEN p_wet < p_desert THEN 'plains' ELSE 'land' END
         WHEN p_wet < p_desert THEN CASE WHEN p_height <= p_salt_height THEN 'salt' WHEN p_wet < p_dunes_wet THEN 'dunes' ELSE 'desert' END
         WHEN p_wet < p_plains THEN 'plains'
         WHEN p_kind = 'land' AND p_warmth >= p_savanna_warmth AND p_wet < p_savanna_wet THEN 'savanna'
         WHEN p_warmth >= p_hot AND p_wet >= p_jungle THEN 'jungle'
         ELSE p_kind END;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_ground_family(p_kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The older ground a kind of ground was split from (more terrain step 1, 2026-10-10): sand dunes and salt flats are
-- desert, bog is swamp, savanna and scrub is open land; every other kind is its own. A coarse cell votes on these first
-- (rpg_map_ground_of), so the new kinds never move a coast, a desert's edge or a river: the cell keeps the ground it
-- had, and shows the commonest of its kinds within it.
SELECT CASE WHEN p_kind IN ('dunes', 'salt') THEN 'desert' WHEN p_kind = 'bog' THEN 'swamp' WHEN p_kind = 'savanna' THEN 'land' ELSE p_kind END;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; 2026-10-10 more
-- terrain, step 1: savanna and scrub, sand dunes, salt flats, bog; rivers and
-- lakes; villages, towns and cities, step 8; roads, step 8b: a road, and a road over mountains, whose range is that of
-- mountains kept to map_road_keep, rpg_map_band; the floors under the ground, step 12d3: of the Deeps +10% to +40%, of a
-- cave +100% to +357% with rubble +400% for one square in eight, of a mine +20% to +80%, a squeeze +300% to +500%, so
-- their average squares are the times a walk under the ground takes, 25, 250, 50 and 400), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
-- detail; the page reads the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent
-- of time a square of it adds to cross it (the most is the same key with _high; rpg_map_band; water goes by its depth,
-- rpg_map_wade_pct; deep water is swum, step 7b; the sea = no walking in), and whether it is forest (it has trees: it burns and
-- hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', 'map_land_penalty', false),
               (3, 'plains', 'Grassy plains', 'g', 'map_plains_penalty', false),
               (3.5, 'savanna', 'Savanna and scrub', 'v', 'map_savanna_penalty', false),
               (4, 'forest', 'Forest', 't', 'map_forest_penalty', true),
               (5, 'pine', 'Pine forest', 'p', 'map_pine_penalty', true),
               (6, 'jungle', 'Jungle', 'j', 'map_jungle_penalty', true),
               (7, 'hills', 'Hills', 'h', 'map_hills_penalty', false),
               (8, 'mountains', 'Mountains', 'm', 'map_mountain_penalty', false),
               (9, 'desert', 'Desert', 'd', 'map_desert_penalty', false),
               (9.3, 'dunes', 'Sand dunes', 'e', 'map_dunes_penalty', false),
               (9.6, 'salt', 'Salt flats', 'f', 'map_salt_penalty', false),
               (10, 'tundra', 'Tundra', 'u', 'map_tundra_penalty', false),
               (11, 'ice', 'Snow and ice', 'i', 'map_ice_penalty', false),
               (12, 'swamp', 'Swamp', 's', 'map_swamp_penalty', false),
               (12.5, 'bog', 'Bog', 'b', 'map_bog_penalty', false),
               (13, 'water', 'Shallow water', 'w', NULL, false),
               (14, 'deep', 'Deep water', 'k', NULL, false),
               (15, 'town', 'Village, town or city', 'n', 'map_town_penalty', false),
               (16, 'road', 'Road', 'r', 'map_road_penalty', false),
               (17, 'pass', 'Mountain road', 'a', NULL, false),
               (18, 'under_deep', 'Floor of the Deeps', 'D', 'map_under_deep_penalty', false),
               (19, 'under_cave', 'Cave floor', 'C', 'map_under_cave_penalty', false),
               (20, 'under_mine', 'Mine floor', 'M', 'map_under_mine_penalty', false),
               (21, 'under_squeeze', 'Squeeze', 'Q', 'map_under_squeeze_penalty', false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_nature(p_deep integer, p_cell integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, height double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground the land itself makes (step 9, 2026-10-04): sea, the kind of unnamed ground, its cover and its climate,
-- at the center of every cell in a block of an even spread of points p_cell squares apart, read with the layers down
-- to grid p_deep whose points are at least p_cell squares apart (finer layers would not show between the points).
-- The one home of the ground of the land; places, rivers and lakes, towns and roads are laid over it by rpg_map_cells.
-- On the cells of one grid (p_deep = the grid, p_cell = its cell) it reads what rpg_map_cells read before step 9; the
-- battle grid reads it so, at every square. Every coarser grid reads it at 3 x 3 points in each of its cells, from
-- the grid under it, and takes what most of them hold (rpg_map_cells).
-- Read in two passes of rpg_map_rolls_set (step 9b, 2026-10-05: one pass for all the rolls a point needs instead of
-- one call a part; the world view fell from about 7 s to about 4): first the height of every point, then, on the
-- points that are land, the kind, the cover grids, warmth and wetness together. The sea is most of the world, and
-- has no kind, cover or climate to read.
-- kind, in this order:
--   sea        its height (the height rolls, part 0, less rpg_map_pole_pull; the same height as rpg_map_heights_on)
--              is below the sea level.
--   mountains  its ground roll (part 1) is within map_mountain_band (6.1) of the middle: mountains run in chains
--              along the middle line of the ground rolls,
--   hills      within map_hills_band (15.8): the hills on both sides of the chains,
--   forest     at or above map_forest_level (31.2): forest lies on the high side, well away from the chains,
--   land       open land, everything else.
-- Then the cover (rpg_map_cover): every grid from the Country grid (map_cover_from, 3) down to the District grid
-- (map_cover_to, 6) that p_deep reaches adds its own scatter of woods, clearings and rough ground, read from the
-- three layers of cover rolls of that grid (part 3), coarsest grid first. The World and Continent grids have no cover.
-- Then the climate (rpg_map_climate, Peter 2026-10-03): snow and ice, tundra, pine forest, desert (with sand dunes and
-- salt flats), savanna and scrub, grassy plains, jungle, swamp and bog. Warmth runs from 100 at the equator to 0 at the poles, moved by map_warmth_share of the warmth
-- rolls (part 4); wetness is the wetness rolls (part 5) moved by map_wet_band with the latitude. Both rolls are read
-- only from the layers whose points are at least map_climate_fine squares apart (one Continent cell), so a spot has
-- the same climate at every zoom; swamp also needs low ground. height = the height of the point.
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_sea_level')::double precision AS sea,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_mountain_band')::double precision AS mountains,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hills_band')::double precision AS hills,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_wood')::double precision AS wood,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_rough')::double precision AS rough,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_clear')::double precision AS clear,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_from')::integer AS cover_from,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_cover_to')::integer AS cover_to,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_forest_level')::double precision AS forest,
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
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_savanna_warmth')::double precision AS savanna_warmth,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_savanna_wet')::double precision AS savanna_wet,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_dunes_wet')::double precision AS dunes_wet,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_salt_height')::double precision AS salt_height,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_pole_pull')::double precision AS pole,
                    (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = 7) AS down),
     ck AS MATERIALIZED (
       -- The grids whose cover this read reaches: from map_cover_from down to p_deep, at most map_cover_to.
       SELECT k.level, k.cell FROM cfg CROSS JOIN public.rpg_map_ladder() k
        WHERE k.level BETWEEN cfg.cover_from AND least(p_deep, cfg.cover_to)),
     rd AS MATERIALIZED (
       -- The readings of the second pass, in order: the kind of ground, the cover rolls of each cover grid (each from
       -- its own three layers, 3 x its level - 2 on, down to points one of its cells apart), warmth and wetness.
       SELECT array_agg(q.part ORDER BY q.o, q.level) AS parts, array_agg(q.frst ORDER BY q.o, q.level) AS frsts,
              array_agg(q.fine ORDER BY q.o, q.level) AS fines, count(*) FILTER (WHERE q.part = 3)::integer AS ncov
         FROM (SELECT 1 AS o, 0 AS level, 1 AS part, 1 AS frst, p_cell AS fine
               UNION ALL
               SELECT 2, ck.level, 3, 3 * ck.level - 2, greatest(ck.cell, p_cell) FROM ck
               UNION ALL
               SELECT 3, 0, 4, 1, greatest(cfg.climate_fine, p_cell) FROM cfg
               UNION ALL
               SELECT 4, 0, 5, 1, greatest(cfg.climate_fine, p_cell) FROM cfg) q),
     h AS MATERIALIZED (
       -- the first pass: the height of every point
       SELECT r.x, r.y, r.vals[1] - public.rpg_map_pole_pull(r.y, p_cell, cfg.pole, cfg.down) AS height
         FROM cfg CROSS JOIN public.rpg_map_rolls_set(ARRAY[0], ARRAY[1], ARRAY[p_cell], p_deep, p_cell, p_x0, p_y0, p_cols, p_rows) r),
     ld AS MATERIALIZED (
       -- the points that are land, numbered across the block row by row from 0 (none: an empty list, so the second
       -- pass reads nothing)
       SELECT coalesce(array_agg((h.y - p_y0) * p_cols + (h.x - p_x0)), '{}'::integer[]) AS at
         FROM h CROSS JOIN cfg WHERE h.height >= cfg.sea),
     g AS MATERIALIZED (
       -- the second pass: the kind, the cover, warmth and wetness of every land point
       SELECT r.x, r.y, r.vals
         FROM rd CROSS JOIN ld
        CROSS JOIN LATERAL public.rpg_map_rolls_set(rd.parts, rd.frsts, rd.fines, p_deep, p_cell, p_x0, p_y0, p_cols, p_rows, ld.at) r)
SELECT h.x, h.y,
       CASE WHEN h.height < cfg.sea THEN 'sea'
            ELSE public.rpg_map_climate(CASE WHEN rd.ncov = 0 THEN b.kind ELSE public.rpg_map_cover(b.kind, g.vals[2:1 + rd.ncov], cfg.wood, cfg.rough, cfg.clear) END,
                                        100 * (1 - e.e) + cfg.warmth_share * g.vals[2 + rd.ncov], g.vals[3 + rd.ncov] + cfg.wet_band * cos(3 * pi() * e.e), h.height - cfg.sea,
                                        cfg.ice, cfg.tundra, cfg.cold, cfg.hot, cfg.desert, cfg.plains, cfg.jungle, cfg.taiga,
                                        cfg.swamp_wet, cfg.swamp_height, cfg.savanna_warmth, cfg.savanna_wet, cfg.dunes_wet, cfg.salt_height) END,
       h.height
  FROM h CROSS JOIN cfg CROSS JOIN rd
  LEFT JOIN g ON g.x = h.x AND g.y = h.y
 CROSS JOIN LATERAL (SELECT CASE WHEN abs(g.vals[1]) < cfg.mountains THEN 'mountains'
                                 WHEN abs(g.vals[1]) < cfg.hills THEN 'hills'
                                 WHEN g.vals[1] >= cfg.forest THEN 'forest'
                                 ELSE 'land' END AS kind) b
 -- e = how far the point is from the equator toward a pole, 0 to 1 (points down the whole world: the squares down
 -- the battle grid over p_cell)
 CROSS JOIN LATERAL (SELECT abs(2 * (h.y + 0.5::double precision) / (cfg.down::double precision / p_cell) - 1) AS e) e;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_ground_of(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground the land makes in each cell of a block of one grid, before water, places, towns and roads (step 14f1 moved
-- it here from rpg_map_cells_make, so the downhill rivers can read the land without reading the rivers). The one home
-- of it. The battle grid reads the land (rpg_map_nature) at every square. Every coarser grid reads it from the grid
-- under it (step 9, Peter 2026-10-04): 9 points in each cell, three across and three down a third of a cell apart, read
-- with the layers down to the next grid; the cell takes the ground most of them hold, a tie going to the ground whose
-- points lie nearer the middle of the cell, then by name. The vote is first on the older ground each kind was split
-- from (rpg_map_ground_family: desert for sand dunes and salt flats), then on the kinds within it. So the coast, the chains, the woods and the climates of a
-- coarse cell are what most of the ground under it is, and zooming in keeps the borders in place, only finer.
WITH lad AS (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     sp AS (SELECT CASE WHEN p_level < 7 THEN 3 ELSE 1 END AS n, least(p_level + 1, 7) AS deep FROM (SELECT 1) one),
     pt AS MATERIALIZED (
       -- the ground at every point read, with the cell it lies in and how far it lies from the middle of that cell
       -- (in points, squared)
       SELECT q.gx, q.gy, q.kind, power(q.x - q.gx * sp.n - (sp.n - 1) / 2.0, 2) + power(q.y - q.gy * sp.n - (sp.n - 1) / 2.0, 2) AS off
         FROM lad CROSS JOIN sp
        CROSS JOIN LATERAL (SELECT nt.x, nt.y, nt.kind, floor(nt.x::double precision / sp.n)::integer AS gx, floor(nt.y::double precision / sp.n)::integer AS gy
                              FROM public.rpg_map_nature(sp.deep, lad.cell / sp.n, p_x0 * sp.n, p_y0 * sp.n, p_cols * sp.n, p_rows * sp.n) nt) q)
SELECT DISTINCT ON (c.gx, c.gy) c.gx, c.gy, c.kind
  FROM (SELECT pt.gx, pt.gy, pt.kind, count(*) AS votes, sum(pt.off) AS off,
               sum(count(*)) OVER (PARTITION BY pt.gx, pt.gy, public.rpg_map_ground_family(pt.kind)) AS fvotes,
               sum(sum(pt.off)) OVER (PARTITION BY pt.gx, pt.gy, public.rpg_map_ground_family(pt.kind)) AS foff,
               public.rpg_map_ground_family(pt.kind) AS fam
          FROM pt GROUP BY pt.gx, pt.gy, pt.kind) c
 ORDER BY c.gx, c.gy, c.fvotes DESC, c.foff, c.fam, c.votes DESC, c.off, c.kind;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_cells_make(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of any block of cells of any grid of the world map, worked out (step 13 moved it here from rpg_map_cells,
-- which reads the saved map first and comes here for what is not saved). The one home of how what a cell is is worked
-- out; a single square under a piece is the same call at the battle grid, 1 by 1.
-- x, y = the cell, counted across the whole world at that level. p_x0, p_y0 = the first cell of the block.
-- kind, in this order:
--   sea        the land (below) is sea there: its height is below the sea level. The sea stays sea under every place.
--   water      rivers and lakes on dry land (rpg_map_water): deep where the middle of the cell is deeper than
--   deep       map_swim_depth (1.2 m, chest-deep: it is swum), else water (it is waded). Water lies over places
--              and every ground; the cell keeps its place (place_id) so a river in the Old Forest is in it.
--   place      its center lies inside a place card with ground of its own (a movement penalty), by the natural
--              edge of that place (rpg_map_within); place_id = the smallest such card. A place fills cells of a
--              grid when its oval covers the center of the cell its own center falls in; only places that fill
--              are ground.
--   town       its center lies inside a village, town or city (rpg_map_town_cells; step 8): their streets and
--              yards. Only the City grid and finer: a coarser grid marks them instead (rpg_map_view_block). On the
--              battle grid (step 3) a square of it that a road, the market place, a street or a lane runs over is
--              road ground instead (below), the rest its yards.
--   road       the battle grid only: a highway, road or lane runs over the square (rpg_map_road_cells; step 8b), or
--              inside a town or city its market place, a street or a lane (rpg_map_street_cells; step 3), the
--   pass       middle of the square within half the width of the road from its line: road, or pass where the ground under
--              it is mountains (a road over a pass keeps its climb). A road over snow and ice is the snow and ice; where
--              a road meets a river or a lake it crosses it: by a bridge (road, ahead of the water) or, where the
--              stretch fords that river (step 11; rpg_map_ford_cells), through the water, which is knee-deep there
--              (water, waded); the sea stops it. A street or a lane stops at the water (only the roads bridge it).
--              Coarser grids draw roads as lines instead.
--   swamp      (step 14f4) dry land in a marsh, a hollow too shallow for a lake (rpg_map_water), unless desert, sand dunes
--              or salt flats (a dry hollow) or snow and ice; bog where the land round it is cold (pine forest, tundra or
--              bog; more terrain step 1).
--   the land  everything else: the ground the land makes (rpg_map_nature): sea, mountains, hills, forest, open
--              land, then woods, clearings and rough ground, then the climates. The battle grid reads it at every
--              square. Every coarser grid reads it from the grid under it (step 9, Peter 2026-10-04): 9 points in each
--              cell, three across and three down a third of a cell apart, read with the layers down to the next grid;
--              the cell takes the ground most of them hold (a tie goes to the ground nearer the middle of the cell).
--              So the coast, the chains, the woods and the climates of a coarse cell are what most of the ground under
--              it is, and zooming in keeps the borders in place, only finer.
-- A place with no movement penalty (a continent, a country) only names the land and never changes a cell.
-- marks = the places with ground that reach into a land cell but are too small or too thin to fill any cell of
-- this grid, smallest first: a village in a 1.2-mile cell, a road 29 feet wide crossing it. Only the places this
-- grid is about are marked: the kind it lists (place_level one below the grid) and every bigger kind. A city is
-- not marked on a Country grid; it shows from the Region grid down.
WITH lad AS (SELECT l.cell, l.down, (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) AS world
               FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS edge,
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
     g AS MATERIALIZED (
       -- The ground the land makes in each cell (rpg_map_ground_of; step 9 and 14f1): what most of the grid under it holds.
       SELECT n.x AS gx, n.y AS gy, n.kind <> 'sea' AS dry, lad.cell, lad.world, n.kind
         FROM lad CROSS JOIN public.rpg_map_ground_of(p_level, p_x0, p_y0, p_cols, p_rows) n),
     wt AS MATERIALIZED (
       -- rivers and lakes on the block (rpg_map_water)
       SELECT w.x, w.y, w.depth, w.marsh FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w),
     tc AS MATERIALIZED (
       -- the cells inside a village, town or city (rpg_map_town_cells): the City grid and finer
       SELECT t.x, t.y FROM public.rpg_map_town_cells(p_level, p_x0, p_y0, p_cols, p_rows) t WHERE p_level >= 5),
     rd AS MATERIALIZED (
       -- the squares a road runs over (rpg_map_road_cells): the battle grid only
       SELECT r.x, r.y FROM public.rpg_map_road_cells(p_level, p_x0, p_y0, p_cols, p_rows) r WHERE p_level = 7),
     st AS MATERIALIZED (
       -- the squares a market place, street or lane inside a town or city runs over (rpg_map_street_cells; step 3)
       SELECT s.x, s.y FROM public.rpg_map_street_cells(p_level, p_x0, p_y0, p_cols, p_rows) s WHERE p_level = 7),
     fd AS MATERIALIZED (
       -- the squares where a road fords the water (rpg_map_ford_cells; step 11): only where a road runs over water
       SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(p_level, p_x0, p_y0, p_cols, p_rows) f
        WHERE p_level = 7 AND f.kind = 'ford' AND EXISTS (SELECT 1 FROM rd JOIN wt ON wt.x = rd.x AND wt.y = rd.y WHERE wt.depth > 0)),
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
            WHEN rd.x IS NOT NULL AND wt.depth > 0 AND fd.x IS NULL THEN 'road'
            WHEN wt.depth >= cfg.swim THEN 'deep'
            WHEN wt.depth > 0 THEN 'water'
            WHEN count(*) FILTER (WHERE h.fills) > 0 THEN 'place'
            WHEN tc.x IS NOT NULL AND rd.x IS NULL AND st.x IS NULL THEN 'town'
            WHEN (rd.x IS NOT NULL OR st.x IS NOT NULL) AND g.kind = 'mountains' THEN 'pass'
            WHEN (rd.x IS NOT NULL OR st.x IS NOT NULL) AND (g.kind <> 'ice' OR tc.x IS NOT NULL) THEN 'road'
            WHEN tc.x IS NOT NULL THEN 'town'
            WHEN wt.marsh AND g.kind NOT IN ('desert', 'dunes', 'salt', 'ice') THEN CASE WHEN g.kind IN ('pine', 'tundra', 'bog') THEN 'bog' ELSE 'swamp' END
            ELSE g.kind END,
       (array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE h.fills))[1],
       coalesce(array_agg(h.id ORDER BY h.area, h.id) FILTER (WHERE NOT h.fills), '{}'::uuid[])
  FROM g
 CROSS JOIN cfg
  LEFT JOIN wt ON wt.x = g.gx AND wt.y = g.gy
  LEFT JOIN tc ON tc.x = g.gx AND tc.y = g.gy
  LEFT JOIN rd ON rd.x = g.gx AND rd.y = g.gy
  LEFT JOIN st ON st.x = g.gx AND st.y = g.gy
  LEFT JOIN fd ON fd.x = g.gx AND fd.y = g.gy
  LEFT JOIN hit h ON g.dry AND h.gx = g.gx AND h.gy = g.gy
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, wt.marsh, cfg.swim, tc.x, rd.x, st.x, fd.x
 ORDER BY g.gy, g.gx;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_weather_table()
 RETURNS TABLE(climate text, kind text, name text, unsettled boolean, weight integer)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The one list of how often each weather comes (weather step 1, 2026-10-09): for each kind of climate, the share of
-- three-hour spells in 100 that each weather takes, and whether a stormy or a fair stretch of days changes it (unsettled:
-- rain, snow, storms, dust; rpg_map_weather_at doubles or halves those). Names come from rpg_map_weathers. Claude
-- estimates, after the share of hours with rain or snow over land on Earth (Dai 2001, J. Climate 14: about 1 hour in 10
-- in wet mild lands, 1 in 100 in deserts) and thunderstorm days (more in the hot wet lands): mild land rains 13 spells in
-- 100 and storms 4; a desert is clear 85.
-- Climates by the ground of the Country cell: mild (open land, plains, forest, hills, towns, roads, lakes), cold
-- (pine forest, bog), hot_wet (jungle), dry (desert, sand dunes, salt flats), savanna (savanna and scrub: a wet season
-- and a long dry one, rain about 1 spell in 9 and storms 6 in 100), tundra, ice (snow and ice), swamp, high (mountains), sea.
SELECT w.climate, w.kind, n.name, w.kind NOT IN ('clear', 'cloudy', 'fog'), w.weight
  FROM (VALUES ('mild', 'clear', 45), ('mild', 'cloudy', 33), ('mild', 'fog', 5), ('mild', 'rain', 13), ('mild', 'storm', 4),
               ('cold', 'clear', 40), ('cold', 'cloudy', 37), ('cold', 'fog', 5), ('cold', 'rain', 8), ('cold', 'snow', 8), ('cold', 'storm', 2),
               ('hot_wet', 'clear', 30), ('hot_wet', 'cloudy', 35), ('hot_wet', 'fog', 5), ('hot_wet', 'rain', 18), ('hot_wet', 'storm', 12),
               ('dry', 'clear', 85), ('dry', 'cloudy', 10), ('dry', 'rain', 1), ('dry', 'storm', 1), ('dry', 'dust', 3),
               ('tundra', 'clear', 40), ('tundra', 'cloudy', 40), ('tundra', 'fog', 6), ('tundra', 'rain', 2), ('tundra', 'snow', 10), ('tundra', 'blizzard', 2),
               ('ice', 'clear', 45), ('ice', 'cloudy', 30), ('ice', 'fog', 5), ('ice', 'snow', 12), ('ice', 'blizzard', 8),
               ('savanna', 'clear', 55), ('savanna', 'cloudy', 24), ('savanna', 'fog', 2), ('savanna', 'rain', 11), ('savanna', 'storm', 6), ('savanna', 'dust', 2),
               ('swamp', 'clear', 30), ('swamp', 'cloudy', 35), ('swamp', 'fog', 15), ('swamp', 'rain', 15), ('swamp', 'storm', 5),
               ('high', 'clear', 40), ('high', 'cloudy', 30), ('high', 'fog', 10), ('high', 'rain', 8), ('high', 'snow', 8), ('high', 'storm', 4),
               ('sea', 'clear', 40), ('sea', 'cloudy', 38), ('sea', 'fog', 7), ('sea', 'rain', 11), ('sea', 'storm', 4)) AS w(climate, kind, weight)
  JOIN public.rpg_map_weathers() n ON n.kind = w.kind;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_weather_at(p_cx integer, p_cy integer, p_ground text, p_clock bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The weather over one Country cell (14.4 miles a side, about the size of one shower or thunderstorm) at a moment of
-- the journey clock: the one home of the weather rule (weather step 1, 2026-10-09). Nothing is stored; the same cell
-- and moment always give the same weather, from fixed-seed d100s (rpg_map_roll, map_seed):
--  * the day is cut into spells of 3 hours from midnight; each spell rolls its weather from the climate of the cell
--    (rpg_map_weather_table, by p_ground, the kind of the Country cell);
--  * 4 spells in 10 keep the weather of the spell before (layer 902), so weather lasts about 5 hours on average;
--  * the Continent cell over it (173 miles, the size of a weather front) rolls a front every 12 hours (layer 903):
--    1 to 50 fair (the unsettled weathers count half), 51 to 80 as usual, 81 to 100 stormy (they count double).
-- Worked: mild land, a stormy front: rain 26, storm 8 of 116, so it rains or storms 29 spells in 100 against 17.
-- It returns the kind, its name, the front, and what the weather does (rpg_map_weathers, step 2a): walk_pct, the
-- percent of time it adds to each square walked, and sight, the squares a person sees in it (null = sight_squares).
DECLARE
  v_tph numeric; v_start numeric; v_seed integer; v_sq numeric;
  v_hour numeric; v_spell bigint; v_front integer; v_mult numeric; v_total numeric; v_aim numeric; v_run numeric := 0;
  v_climate text; v_r record; v_kind text := 'clear'; v_e record;
BEGIN
  SELECT max(s.value) FILTER (WHERE s.key = 'ticks_per_hour'), max(s.value) FILTER (WHERE s.key = 'journey_start_hour'),
         max(s.value) FILTER (WHERE s.key = 'map_seed')::integer, max(s.value) FILTER (WHERE s.key = 'map_square_m')
    INTO v_tph, v_start, v_seed, v_sq
    FROM public.rpg_settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('ticks_per_hour', 'journey_start_hour', 'map_seed', 'map_square_m');
  v_climate := CASE p_ground WHEN 'sea' THEN 'sea' WHEN 'pine' THEN 'cold' WHEN 'bog' THEN 'cold' WHEN 'jungle' THEN 'hot_wet' WHEN 'desert' THEN 'dry'
                             WHEN 'dunes' THEN 'dry' WHEN 'salt' THEN 'dry' WHEN 'savanna' THEN 'savanna'
                             WHEN 'tundra' THEN 'tundra' WHEN 'ice' THEN 'ice' WHEN 'swamp' THEN 'swamp'
                             WHEN 'mountains' THEN 'high' WHEN 'pass' THEN 'high' ELSE 'mild' END;
  v_hour := greatest(coalesce(p_clock, 0), 0) / v_tph + v_start;
  v_spell := floor(v_hour / 3);
  IF public.rpg_map_roll(v_seed, 902, p_cx, p_cy + 1000 * v_spell::integer) <= 40 AND v_spell > 0 THEN v_spell := v_spell - 1; END IF;
  v_front := public.rpg_map_roll(v_seed, 903, p_cx / 12, p_cy / 12 + 1000 * (v_spell / 4)::integer);
  v_mult := CASE WHEN v_front <= 50 THEN 0.5 WHEN v_front <= 80 THEN 1 ELSE 2 END;
  SELECT sum(t.weight * CASE WHEN t.unsettled THEN v_mult ELSE 1 END) INTO v_total
    FROM public.rpg_map_weather_table() t WHERE t.climate = v_climate;
  v_aim := (public.rpg_map_roll(v_seed, 901, p_cx, p_cy + 1000 * v_spell::integer) - 0.5) / 100 * v_total;
  FOR v_r IN SELECT t.kind, t.weight * CASE WHEN t.unsettled THEN v_mult ELSE 1 END AS w
               FROM public.rpg_map_weather_table() t WHERE t.climate = v_climate LOOP
    v_run := v_run + v_r.w;
    IF v_aim < v_run THEN v_kind := v_r.kind; EXIT; END IF;
  END LOOP;
  SELECT * INTO v_e FROM public.rpg_map_weathers() e WHERE e.kind = v_kind;
  RETURN jsonb_build_object('kind', v_e.kind, 'name', v_e.name,
                            'front', CASE WHEN v_front <= 50 THEN 'fair' WHEN v_front <= 80 THEN 'usual' ELSE 'stormy' END,
                            'walk_pct', v_e.walk_pct,
                            'sight', CASE WHEN v_e.sight_miles IS NULL THEN NULL ELSE round(v_e.sight_miles * 1609.344 / v_sq) END);
END $function$;
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
-- More terrain step 1 (2026-10-10): savanna and scrub weighs as open land (the ground it was), bog as swamp, sand
-- dunes half of desert (ruins in full: cities buried in sand), salt flats a fifth of desert.
-- Nothing stands in the sea, in water, on snow and ice, on a road or a street, or inside a place with ground of its own.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (1, 'peak',   'peak',   'Great peak',      0.6,  4500, 6000, 30000, 60000, '{A}{B}',            ARRAY['horn', 'peak', 'spire'],           '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2, "savanna": 0.3, "dunes": 0.15, "salt": 0.06}'),
    (1, 'ruins',  'ruins',  'Ruined city',     0.4,    40,   70,  3000,  9000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (2, 'peak',   'peak',   'Peak',            0.45, 2500, 4500, 15000, 40000, '{A}{B}',            ARRAY['horn', 'pike', 'fell'],            '{"mountains": 1, "hills": 0.6, "land": 0.3, "plains": 0.3, "desert": 0.3, "tundra": 0.3, "jungle": 0.25, "forest": 0.2, "pine": 0.2, "savanna": 0.3, "dunes": 0.15, "salt": 0.06}'),
    (2, 'castle', 'castle', 'Fortress',        0.3,    30,   50,   400,  1200, 'The Fortress of {A}{B}', ARRAY['hold', 'gard', 'mont', 'crest'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1}'),
    (2, 'ruins',  'ruins',  'Ruined city',     0.25,   20,   45,  1000,  3000, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'haven', 'mont'], '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (3, 'peak',   'peak',   'Mountain',        0.3,   800, 2500,  4000, 15000, '{A}{B}',            ARRAY['fell', 'pike', 'crag', 'howe'],    '{"mountains": 1}'),
    (3, 'castle', 'castle', 'Castle',          0.3,    25,   35,    80,   250, '{A}{B} Castle',     ARRAY['hold', 'gard', 'mont', 'crest', 'wall', 'keep'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1}'),
    (3, 'ruins',  'ruins',  'Ruined castle',   0.2,    15,   30,    60,   200, 'The Ruins of {A}{B}', ARRAY['hold', 'gard', 'wall', 'keep'],  '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (3, 'tower',  'tower',  'Great tower',     0.2,    35,   60,    10,    18, '{A} Tower',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08}'),
    (4, 'peak',   'peak',   'Hill',            0.2,   150,  800,   800,  4000, '{A} {B}',           ARRAY['Tor', 'Fell', 'Howe', 'Law', 'Knott'], '{"mountains": 1, "hills": 1}'),
    (4, 'castle', 'castle', 'Tower house',     0.15,   15,   25,    20,    60, '{A}{B} Keep',       ARRAY['hold', 'gard', 'mont', 'crest', 'wall'], '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1}'),
    (4, 'ruins',  'ruins',  'Ruined chapel',   0.2,     8,   20,    10,    30, '{A} Chapel',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (4, 'tower',  'tower',  'Watchtower',      0.2,    15,   30,     6,    10, '{A} Watch',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08}'),
    (4, 'stones', 'stones', 'Stone circle',    0.25,    2,    5,    30,   110, 'The {A} Stones',    ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04}'),
    (5, 'peak',   'peak',   'Crag',            0.2,    30,  150,   100,   600, '{A} {B}',           ARRAY['Crag', 'Scar', 'Knott', 'Nab'],    '{"mountains": 1, "hills": 1}'),
    (5, 'castle', 'castle', 'Motte',           0.1,     8,   15,    30,    60, '{A} Mount',         ARRAY[''],                                '{"land": 1, "plains": 0.8, "hills": 1, "forest": 0.5, "pine": 0.3, "jungle": 0.2, "desert": 0.2, "tundra": 0.2, "mountains": 0.3, "swamp": 0.1, "savanna": 1, "dunes": 0.1, "salt": 0.04, "bog": 0.1}'),
    (5, 'ruins',  'ruins',  'Ruined croft',    0.25,    3,    6,     6,    15, '{A} Croft',         ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (5, 'tower',  'tower',  'Beacon',          0.15,    6,   12,     3,     6, '{A} Beacon',        ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "mountains": 0.4, "tundra": 0.4, "desert": 0.4, "forest": 0.3, "pine": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08}'),
    (5, 'stone',  'stone',  'Great standing stone', 0.3, 4,   8,     1,   2.5, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04}'),
    (6, 'rock',   'rock',   'Boulder',         0.35,    2,    8,     3,    12, '{A} Rock',          ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.7, "desert": 0.6, "land": 0.5, "plains": 0.4, "forest": 0.4, "pine": 0.4, "savanna": 0.5, "dunes": 0.3, "salt": 0.12}'),
    (6, 'ruins',  'ruins',  'Broken wall',     0.2,   1.5,    4,     2,     8, '{A} Wall',          ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 0.8, "forest": 1, "pine": 0.6, "jungle": 1, "desert": 1, "swamp": 0.8, "tundra": 0.5, "mountains": 0.4, "savanna": 0.8, "dunes": 1, "salt": 0.2, "bog": 0.8}'),
    (6, 'stone',  'stone',  'Standing stone',  0.3,   1.2,  3.5,   0.5,   1.2, 'The {A} Stone',     ARRAY[''],                                '{"land": 0.8, "plains": 0.8, "hills": 1, "tundra": 0.6, "desert": 0.2, "forest": 0.2, "pine": 0.2, "mountains": 0.2, "savanna": 0.8, "dunes": 0.1, "salt": 0.04}'),
    (6, 'cairn',  'cairn',  'Cairn',           0.15,    1,    3,     2,     6, '{A} Cairn',         ARRAY[''],                                '{"hills": 1, "mountains": 1, "tundra": 0.8, "desert": 0.4, "land": 0.3, "plains": 0.3, "pine": 0.2, "savanna": 0.3, "dunes": 0.2, "salt": 0.08}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;
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
-- More terrain step 1 (2026-10-10): savanna and scrub weighs as open land (the ground it was), bog as swamp, sand dunes
-- half of desert, salt flats a fifth of desert.
SELECT v.rank, v.kind, v.icon, v.words, v.weight::double precision, v.h_low::double precision, v.h_high::double precision,
       v.w_low::double precision, v.w_high::double precision, v.pattern, v.ends, v.grounds::jsonb
  FROM (VALUES
    (4, 'cave',   'cave',   'Great cave',      0.4,    15,   40,    40,   120, '{A} {B}', ARRAY['Cavern', 'Caves', 'Deeps'],     '{"mountains": 1, "hills": 0.8}'),
    (4, 'mine',   'mine',   'Mine workings',   0.3,     6,   15,    60,   200, '{A} {B}', ARRAY['Mine', 'Delving', 'Workings'],  '{"mountains": 1, "hills": 0.8, "tundra": 0.2}'),
    (4, 'camp',   'camp',   'War camp',        0.3,     3,    5,    80,   200, '{A} {B}', ARRAY['Camp', 'Stockade'],             '{"plains": 1, "land": 0.8, "hills": 0.6, "forest": 0.6, "pine": 0.5, "desert": 0.4, "tundra": 0.3, "jungle": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08}'),
    (5, 'cave',   'cave',   'Cave',            0.3,     6,   20,    15,    40, '{A} {B}', ARRAY['Cave', 'Hole', 'Grotto'],       '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3, "jungle": 0.3}'),
    (5, 'mine',   'mine',   'Mine',            0.15,    3,    8,    15,    40, '{A} {B}', ARRAY['Mine', 'Adit', 'Delving'],      '{"mountains": 1, "hills": 0.8}'),
    (5, 'shrine', 'shrine', 'Shrine',          0.2,     4,    8,     5,    10, '{A} {B}', ARRAY['Shrine', 'Sanctum'],            '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "bog": 0.3}'),
    (5, 'camp',   'camp',   'Camp',            0.15,    2,    3,    20,    50, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3, "savanna": 0.6, "dunes": 0.25, "salt": 0.1, "bog": 0.3}'),
    (5, 'hut',    'hut',    'Hut',             0.2,     3,    5,     5,     9, '{A} {B}', ARRAY['Hut', 'Lodge', 'Bothy'],        '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3, "savanna": 0.8, "dunes": 0.15, "salt": 0.06, "bog": 0.5}'),
    (6, 'cave',   'cave',   'Hollow',          0.3,     3,    8,     6,    15, '{A} {B}', ARRAY['Hollow', 'Hole'],               '{"mountains": 1, "hills": 1, "forest": 0.3, "pine": 0.3}'),
    (6, 'shrine', 'shrine', 'Wayside shrine',  0.25,    2,  3.5,     1,   2.5, '{A} {B}', ARRAY['Cross', 'Shrine'],              '{"hills": 1, "land": 0.8, "plains": 0.8, "forest": 0.8, "pine": 0.6, "jungle": 0.6, "mountains": 0.5, "desert": 0.4, "tundra": 0.4, "swamp": 0.3, "savanna": 0.8, "dunes": 0.2, "salt": 0.08, "bog": 0.3}'),
    (6, 'camp',   'camp',   'Campsite',        0.2,   1.5,  2.5,     8,    15, '{A} {B}', ARRAY['Camp'],                        '{"forest": 1, "pine": 1, "plains": 0.8, "land": 0.6, "hills": 0.6, "jungle": 0.6, "desert": 0.5, "tundra": 0.4, "swamp": 0.3, "savanna": 0.6, "dunes": 0.25, "salt": 0.1, "bog": 0.3}'),
    (6, 'hut',    'hut',    'Hut',             0.25,    3,  4.5,     4,     7, '{A} {B}', ARRAY['Hut', 'Bothy'],                 '{"forest": 1, "pine": 1, "hills": 1, "land": 0.8, "plains": 0.8, "mountains": 0.6, "tundra": 0.6, "jungle": 0.6, "swamp": 0.5, "desert": 0.3, "savanna": 0.8, "dunes": 0.15, "salt": 0.06, "bog": 0.5}')
  ) AS v(rank, kind, icon, words, weight, h_low, h_high, w_low, w_high, pattern, ends, grounds);
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_town_make(p_x bigint, p_y bigint, p_city boolean, p_town boolean, p_rolls integer[], p_country text, p_region text)
 RETURNS TABLE(kind text, name text, people integer, r double precision, shape double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What grows at a site (rpg_map_town_sites), the one home of it (step 8): a city, a town, a village or nothing, how
-- many people live there, how far it reaches, its name and how its edge wanders. Worked out when asked, never stored.
-- A great city (step 12a; Peter 2026-10-04 13:44: huge cities) is decided first: the city site of the city square its
-- great-city square picked (rpg_map_great; map_great_city_lattice, 3 x 3 city squares, 259 miles, about the size of
-- England and Wales, which c. 1300 had one city far above the rest, London) grows one on the same roll a city takes,
-- under map_great_city_share times how well the ground of its Continent cell is settled, counted twice: once for the
-- site to hold a city at all, once for the land round it to feed a great one (open land 0.6, forest 0.15, hills 0.22,
-- mountains or swamp 1 in 75; the cell read through rpg_map_kinds and kept for the transaction), and only where its
-- own square is dry land (rpg_map_heights_on at the battle grid), so no great city stands in the sea. Else the site
-- may still grow a city.
-- The site of a city grows a city when its roll is under map_city_share times how well the ground of its Country cell is
-- settled (map_settle_<ground>); if not, the site of a town grows a town on map_town_share times the ground of its Region
-- cell; if not, any site grows a village on map_village_share times the ground of its Region cell. The shares make
-- good open land as crowded as the farmland of England was: the Domesday Book (1086) names about 13,400 places in England,
-- one for every 3.7 square miles, a village every 2.1 miles; about 800 market towns served England and Wales c. 1600
-- (Everitt 1967), one for every 73 square miles; four English cities held 10,000 people or more c. 1300 (London,
-- York, Norwich, Bristol), one for every 12,600 square miles. The ground thins them, as farming country does: forest
-- half as many, hills 0.6, savanna and scrub 1 (as the open land it was), pine forest and jungle 0.2, mountains and swamp
-- 0.15, bog 0.1, desert and tundra 0.05, sand dunes 0.01, none on salt flats, on snow and ice, on water or in the sea. Nothing grows inside a place with ground of its own (a haunt, Old Forest, Haven) or
-- within map_town_clear (300 squares, 1,100 feet) of one.
-- people: a steady roll from the least to the most of its kind (map_<kind>_people_low / _high), as many small ones as
-- big on a doubling scale (100 to 400 a village: half under 200), rounded to 10. r = rpg_map_town_radius.
-- shape: how its edge wanders round its middle, three waves of 2, 3 and 4 bumps a turn, of up to half, three tenths
-- and a fifth of map_town_edge (12 in 100) of r: [size, turn] of each.
-- name: a first part and an ending, the way English places were named (Ash + ford, Oak + ham, Thorn + bury);
-- the ending of a village fits its ground (a wood, a hill, a mere), that of a town or a city its size.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     -- a great city: this is the city site its great-city square picked, and the roll could grow one on the best ground
     gc AS MATERIALIZED (
       SELECT q.x2, q.y2, q.wx, floor(q.cx::double precision / q.ng)::bigint AS gx, floor(q.cy::double precision / q.ng)::bigint AS gy
              FROM (SELECT gl.seed, gl.ng, gl.ag, floor(p_x::double precision / gl.lc)::bigint AS cx, floor(p_y::double precision / gl.lc)::bigint AS cy,
                           floor(p_x::double precision / c.c2)::integer AS x2, floor(p_y::double precision / c.c2)::integer AS y2,
                           mod(mod(p_x, c.world) + c.world, c.world)::integer AS wx
                      FROM public.rpg_map_great_lattice() gl
                     CROSS JOIN (SELECT max(w.cell) FILTER (WHERE w.level = 2)::bigint AS c2, max(w.span) FILTER (WHERE w.level = 1)::bigint AS world FROM public.rpg_map_ladder() w) c
                     WHERE p_city AND (p_rolls[1] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_great_city_share')) q
             CROSS JOIN LATERAL public.rpg_map_great(floor(q.cx::double precision / q.ng)::bigint, floor(q.cy::double precision / q.ng)::bigint, q.seed, q.ng, q.ag) g
             WHERE g.cx = q.cx AND g.cy = q.cy),
     -- then the ground of its Continent cell, then dry land under its own middle
     g2 AS MATERIALIZED (SELECT gc.wx FROM gc CROSS JOIN LATERAL public.rpg_map_kinds(2, gc.x2, gc.y2, 1, 1) k2
             WHERE (p_rolls[1] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_great_city_share')
                                              * power(coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || k2.kind), 0), 2)),
     g3 AS MATERIALIZED (SELECT 1 FROM g2 CROSS JOIN LATERAL public.rpg_map_heights_on(7, 1, g2.wx, p_y::integer, 1, 1) h
             WHERE h.height >= (SELECT st.value FROM st WHERE st.key = 'map_sea_level')),
     k AS MATERIALIZED (SELECT CASE WHEN EXISTS (SELECT 1 FROM g3) THEN 'great_city'
                       WHEN p_city AND (p_rolls[1] - 0.5) / 100
                                       < (SELECT st.value FROM st WHERE st.key = 'map_city_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_country), 0) THEN 'city'
                       WHEN p_town AND (p_rolls[2] - 0.5) / 100
                                       < (SELECT st.value FROM st WHERE st.key = 'map_town_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_region), 0) THEN 'town'
                       WHEN (p_rolls[3] - 0.5) / 100
                            < (SELECT st.value FROM st WHERE st.key = 'map_village_share') * coalesce((SELECT st.value FROM st WHERE st.key = 'map_settle_' || p_region), 0) THEN 'village' END AS kind),
     pp AS (SELECT k.kind, (round(b.lo * power(b.hi / b.lo, (p_rolls[4] - 0.5) / 100) / 10) * 10)::integer AS people
              FROM k
             CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_' || k.kind || '_people_low')::double precision AS lo,
                                        (SELECT st.value FROM st WHERE st.key = 'map_' || k.kind || '_people_high')::double precision AS hi) b
             WHERE k.kind IS NOT NULL),
     rr AS (SELECT pp.kind, pp.people, public.rpg_map_town_radius(pp.kind, pp.people) AS r,
                   (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision AS edge,
                   (SELECT st.value FROM st WHERE st.key = 'map_town_clear')::double precision AS clear
              FROM pp),
     nm AS (SELECT ARRAY['Ash', 'Oak', 'Elm', 'Thorn', 'Hazel', 'Alder', 'Birch', 'Willow', 'Holly', 'Rowan', 'Yew', 'Stone',
                         'Clay', 'Chalk', 'Flint', 'Mill', 'Brook', 'Well', 'Moor', 'Heath', 'Black', 'White', 'Red', 'Green',
                         'Long', 'Broad', 'High', 'North', 'South', 'East', 'West', 'Kings', 'Queens', 'Bishops', 'Abbots', 'Swan',
                         'Hart', 'Fox', 'Hawk', 'Crane', 'Buck', 'Ox', 'Barley', 'Wheat', 'Apple', 'Honey', 'Salt', 'Iron',
                         'Bell', 'Cross', 'Fair', 'Bright', 'Wolf', 'Hare', 'Lark', 'Wren', 'Elder', 'Cold', 'Wind', 'Rush',
                         'Reed', 'Hay', 'Cherry', 'Merry'] AS firsts,
                   -- a great city (step 12a) names itself after a river, as Exeter, Tynemouth and Doncaster did: 64 rivers
                   -- of England, none of them a first part of the names above, so no village, town or city shares a
                   -- great city name
                   ARRAY['Avon', 'Alde', 'Arun', 'Axe', 'Bure', 'Brue', 'Calder', 'Cam', 'Char', 'Colne', 'Dart', 'Deben',
                         'Dove', 'Eden', 'Esk', 'Exe', 'Fowey', 'Frome', 'Glen', 'Hodder', 'Humber', 'Irwell', 'Isis', 'Itchen',
                         'Kennet', 'Lea', 'Lune', 'Medway', 'Mersey', 'Nene', 'Ouse', 'Parrett', 'Ribble', 'Roding', 'Rother', 'Severn',
                         'Soar', 'Stour', 'Swale', 'Tamar', 'Taw', 'Tees', 'Teme', 'Test', 'Thame', 'Torridge', 'Trent', 'Tyne',
                         'Ure', 'Usk', 'Wear', 'Welland', 'Wey', 'Wharfe', 'Witham', 'Wye', 'Yare', 'Yeo', 'Aire', 'Derwent',
                         'Kent', 'Mole', 'Otter', 'Lugg'] AS rivers,
                   CASE WHEN rr.kind = 'great_city' THEN ARRAY['chester', 'cester', 'caster', 'minster', 'mouth', 'borough', 'bury', 'ford']
                        WHEN rr.kind = 'city' THEN ARRAY['bury', 'chester', 'minster', 'caster', 'ford', 'bridge', 'ham', 'borough', 'wick']
                        WHEN rr.kind = 'town' THEN ARRAY['ford', 'bridge', 'ham', 'ton', 'bury', 'wick', 'field', 'stow', 'borough', 'worth']
                        WHEN p_region IN ('forest', 'pine', 'jungle') THEN ARRAY['wood', 'hurst', 'den', 'ley', 'holt', 'field', 'ridge']
                        WHEN p_region IN ('hills', 'mountains') THEN ARRAY['don', 'combe', 'ley', 'hill', 'low', 'dale', 'side']
                        WHEN p_region IN ('swamp', 'bog') THEN ARRAY['mere', 'fen', 'ey', 'marsh', 'holm']
                        WHEN p_region IN ('desert', 'dunes', 'salt', 'tundra') THEN ARRAY['well', 'stead', 'by', 'cote']
                        ELSE ARRAY['ton', 'ham', 'stead', 'thorpe', 'by', 'wick', 'cote', 'worth', 'field', 'ley', 'well', 'brook', 'ford'] END AS ends
              FROM rr),
     pn AS (SELECT CASE WHEN g.gx IS NULL THEN nm.firsts[1 + mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, cardinality(nm.firsts))]
                        -- a great city: its river by where its great-city square sits in each block of 4 x 4 of them
                        -- (1,036 miles) and a roll for which of four, so no two great cities of such a block share one
                        ELSE nm.rivers[1 + mod(mod(g.gx, 4) + 4, 4) + 4 * mod(mod(g.gy, 4) + 4, 4) + 16 * mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, 4)] END AS a,
                   nm.ends[1 + mod((p_rolls[7] - 1) * 100 + p_rolls[8] - 1, cardinality(nm.ends))] AS b
              FROM nm LEFT JOIN (SELECT gc.gx, gc.gy FROM gc CROSS JOIN rr WHERE rr.kind = 'great_city') g ON true)
SELECT rr.kind,
       CASE WHEN lower(right(pn.a, 1)) = left(pn.b, 1) THEN pn.a || substr(pn.b, 2) ELSE pn.a || pn.b END,
       rr.people, rr.r,
       ARRAY[rr.edge * 0.5 * ((p_rolls[9] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[10] - 0.5) / 100,
             rr.edge * 0.3 * ((p_rolls[11] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[12] - 0.5) / 100,
             rr.edge * 0.2 * ((p_rolls[13] - 0.5) / 50 - 1), 2 * pi() * (p_rolls[14] - 0.5) / 100]
  FROM rr CROSS JOIN pn
 CROSS JOIN (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) l
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures c
                    WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL AND c.place_penalty IS NOT NULL
                      AND public.rpg_map_covers(p_x + 0.5::double precision, p_y + 0.5::double precision, c.place_x, c.place_y,
                                                ceil(c.place_w + 2 * (rr.r + rr.clear))::integer, ceil(c.place_h + 2 * (rr.r + rr.clear))::integer, l.span));
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_lie(p_kind text, p_shore boolean, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What lies on one square of the battle grid (step 14f-battle, Peter 2026-10-08 18:52, 1A), the one home of it, by its
-- ground and one fixed d100 of the square (rpg_map_roll, layer 1801), so nothing is stored:
--   boulder  hills (map_boulder_hills_share, 2 in 100 squares) and mountains (map_boulder_mountains_share, 6): a rock
--            higher than a person. Nobody walks into it, and a fighter just behind one from the attacker is in full
--            cover (rpg_cover).
--   log      forest, pine forest and jungle (map_log_share, 3 in 100: fallen trunks cover a few in 100 of the floor of
--            a forest, Harmon et al. 1986, Ecology of coarse woody debris in temperate ecosystems). It adds
--            map_log_penalty (+100%) to the time the square takes, and a fighter just behind one from the attacker is
--            in half cover (rpg_cover).
--   reeds    dry ground at the edge of a river or a lake (p_shore), unless desert, sand dunes, salt flats or snow and ice (map_shore_reed_share,
--            50 in 100). Drawn only.
-- rpg_map_costs reads it for every battle grid square it may lie on (not a road, a town, a place, a building or a cliff).
SELECT CASE
         WHEN p_kind = 'hills' AND r.d <= s.bh THEN 'boulder'
         WHEN p_kind = 'mountains' AND r.d <= s.bm THEN 'boulder'
         WHEN p_kind IN ('forest', 'pine', 'jungle') AND r.d <= s.lg THEN 'log'
         WHEN p_shore AND p_kind NOT IN ('desert', 'dunes', 'salt', 'ice', 'sea', 'water', 'deep') AND r.d > 100 - s.rd THEN 'reeds'
       END
  FROM (SELECT public.rpg_map_roll((SELECT st.value FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st.key = 'map_seed')::integer,
                                   1801, p_x, p_y) AS d) r
 CROSS JOIN (SELECT max(st.value) FILTER (WHERE st.key = 'map_boulder_hills_share') AS bh,
                    max(st.value) FILTER (WHERE st.key = 'map_boulder_mountains_share') AS bm,
                    max(st.value) FILTER (WHERE st.key = 'map_log_share') AS lg,
                    max(st.value) FILTER (WHERE st.key = 'map_shore_reed_share') AS rd
               FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365') s;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision, lie text)
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
-- water too rough to swim. On the battle grid a square that is a cliff (rpg_map_cliffs: a mountain cliff, or a gorge wall in hills or
-- mountains; step 7c, canyons) is climbed: its percent is the climb's (rpg_map_climb: 60 degrees +2,688%) and its hard is 1, the darkest.
-- A square a house stands on (rpg_map_building_cells; step 8c) is climbed too: its wall's or roof's percent (a wall
-- 2.6 m to the eaves +3,644%, a roof square at 50 degrees +1,818%); the ground under it keeps its kind and how hard it
-- is, and the sea stays the sea. So is a square a landmark stands on (step 12b2): a castle wall 13 m high, sheer.
-- On the battle grid (step 14f-battle) what lies on a square (rpg_map_lie; lie): a boulder no way in (no percent), a
-- fallen log map_log_penalty (+100%) on top of its ground's percent, reeds at a river's or a lake's edge nothing; only on
-- ground of its own, not a road, a town, a place, a building or a cliff.
-- The one way a block of the map is read with its costs: fight boards (rpg_fight_squares) and the Maps tab
-- (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the water's depth and pull only when the block holds water shallow enough to wade, or deep water on the battle
     -- grid (deep water is shaded full; on a coarser grid it is the average swim)
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth, w.current FROM public.rpg_map_flow(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind = 'water' OR (p_level = 7 AND c.kind = 'deep'))),
     -- cliffs (rpg_map_cliffs): on the battle grid, only when the block holds hills or mountains; each square at the angle
     -- its own ground gives it (a mountain cliff, or a gorge wall in hills or mountains; canyons, 2026-10-09)
     cl AS MATERIALIZED (SELECT t.x, t.y, m.pct
                           FROM public.rpg_map_cliffs(p_level, p_x0, p_y0, p_cols, p_rows) t
                           JOIN c ON c.x = t.x AND c.y = t.y
                          CROSS JOIN LATERAL public.rpg_map_climb(CASE c.kind WHEN 'mountains' THEN t.mountains WHEN 'hills' THEN t.hills END) m
                          WHERE p_level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('mountains', 'hills'))),
     -- houses: on the battle grid, only when the block holds the ground of a village, town or city, or of a place, or a
     -- landmark stands on it (step 12b2)
     bd AS MATERIALIZED (SELECT b.x, b.y, b.pct FROM public.rpg_map_building_cells(p_level, p_x0, p_y0, p_cols, p_rows) b
                          WHERE p_level = 7 AND (EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                                 OR EXISTS (SELECT 1 FROM public.rpg_map_landmark_cells(p_level, p_x0, p_y0, p_cols, p_rows)))),
     -- what lies on each square (step 14f-battle): the battle grid only; the shore is dry ground beside a river's or a
     -- lake's water
     li AS MATERIALIZED (
       SELECT c.x, c.y, public.rpg_map_lie(c.kind, EXISTS (SELECT 1 FROM c n WHERE n.kind IN ('water', 'deep') AND abs(n.x - c.x) + abs(n.y - c.y) = 1), c.x, c.y) AS lie
         FROM c
        WHERE p_level = 7 AND c.kind IN ('hills', 'mountains', 'forest', 'pine', 'jungle', 'land', 'plains', 'savanna', 'swamp', 'bog', 'tundra')),
     lp AS (SELECT s.value::integer AS pen FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_log_penalty'),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN bd.x IS NOT NULL AND c.kind <> 'sea' THEN bd.pct
            WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            WHEN c.kind = 'deep' THEN CASE WHEN wt.x IS NOT NULL AND public.rpg_map_swim_difficulty(wt.current) IS NULL THEN NULL
                                           ELSE public.rpg_map_wade_pct(coalesce(wt.depth, sw.swim)) END
            WHEN c.kind IN ('mountains', 'hills') AND cl.x IS NOT NULL THEN cl.pct
            WHEN li.lie = 'boulder' THEN NULL
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) + CASE WHEN li.lie = 'log' THEN lp.pen ELSE 0 END END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1)
            WHEN c.kind IN ('mountains', 'hills') AND cl.x IS NOT NULL THEN 1 ELSE h.hard END,
       CASE WHEN bd.x IS NULL AND cl.x IS NULL AND c.place_id IS NULL THEN li.lie END
  FROM c
 CROSS JOIN sw
 CROSS JOIN lp
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN cl ON cl.x = c.x AND cl.y = c.y
  LEFT JOIN bd ON bd.x = c.x AND bd.y = c.y
  LEFT JOIN li ON li.x = c.x AND li.y = c.y AND bd.x IS NULL AND cl.x IS NULL AND c.place_id IS NULL
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_drain_make()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the water of the Continent grid runs (step 14f1, Peter 2026-10-07 18:21: rivers start on high ground, run
-- downhill, end in the sea or in lakes or marshes, and lakes drain on by a river). Worked out from the land itself:
-- the height of every Continent cell (rpg_map_heights, the rolls that make land and sea) and its ground
-- (rpg_map_ground_of). Nothing here is rolled; the same land always gives the same rivers. rpg_map_drainage keeps it.
-- How (the standard way water is routed over a height map):
--  * Every cell's water goes to one of its eight neighbours (O'Callaghan & Mark 1984), never across another flow
--    corner to corner. The cell it goes to is found by flooding the land up from the sea, lowest first (priority
--    flood: Planchon & Darboux 2002; Barnes, Lehman & Mulla 2014): each land cell drains to the cell the flood reached
--    it from, so all water runs down to the sea.
--  * A hollow the flood has to fill (land lower than the rim round it) holds water up to the rim, and drains out at
--    the lowest point of the rim: a lake that drains on by a river. Only a hollow at least map_lake_2_hollow deep
--    holds a great lake (shallower ones are flats the river runs through, the way small sinks in real height data
--    are only noise).
--  * Each cell gathers the water of every cell that drains through it (its own counting 1, a desert, sand dunes or salt
--    flats map_drain_desert:
--    dry land sends on little water). Where at least map_drain_great cells drain (6 Continent cells, about half a
--    million square kilometres: the basins Earth's rivers 400 m wide drain, about 50 of them on Earth's land, and this
--    world has half as much land again) a great river runs. The river out of every great lake runs down to the sea or
--    to a great river: a great river where enough water has gathered, a river before that.
-- Returns {pieces: [...], lakes: [...]}, in Continent cells (a cell's middle is its number + 0.5; the map wraps east
-- to west, so a piece may start or end just past the edge):
--  pieces: [id, ax, ay, cx, cy, bx, by, k_start, k_end, start, joins] = one bend of a river, a curve from (ax, ay)
--    toward (cx, cy) and on to (bx, by) (a quadratic curve, the way the Maps tab draws rivers through the middles
--    between their points); k = the size of river (2 great river, 3 river) where it starts and where it ends;
--    start = 1 where a river rises (its first bend); joins = the id of the bend of the bigger river it joins at that
--    bend's middle, else 0.
--  lakes: [fill, [x, y], ...] = each great lake: the height it fills to and its cells.
--  dn, acc, ch, wt (step 14f2): each cell's own numbers, below.
DECLARE
  v_w integer; v_h integer; v_n integer;
  v_hollow double precision; v_great double precision; v_desert double precision;
  h double precision[]; land boolean[]; wt double precision[];
  fill double precision[]; dn integer[]; done boolean[]; ord integer[] := '{}'; acc double precision[];
  hk double precision[] := '{}'; hc integer[] := '{}'; hd integer[] := '{}'; hn integer := 0;
  lk integer[]; isriv boolean[]; kk integer[]; up integer[];
  i integer; j integer; c integer; d integer; nb integer; dx integer; dy integer; x integer; y integer;
  f double precision; t double precision; e integer; p integer;
  kx double precision; ky double precision; ix integer;
  v_pieces jsonb := '[]'; v_lakes jsonb := '[]'; v_id integer := 0; v_main integer[];
  st integer[]; grp integer[]; ng integer := 0; gdeep double precision[] := '{}';
  v_eps constant double precision := 1e-6;
BEGIN
  SELECT l.across, l.down INTO v_w, v_h FROM public.rpg_map_ladder() l WHERE l.level = 2;
  v_n := v_w * v_h;
  SELECT max(s.value) FILTER (WHERE s.key = 'map_lake_2_hollow'), max(s.value) FILTER (WHERE s.key = 'map_drain_great'),
         max(s.value) FILTER (WHERE s.key = 'map_drain_desert')
    INTO v_hollow, v_great, v_desert
    FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  h := array_fill(0::double precision, ARRAY[v_n]); land := array_fill(false, ARRAY[v_n]); wt := array_fill(1::double precision, ARRAY[v_n]);
  FOR x, y, f IN SELECT r.x, r.y, r.height FROM public.rpg_map_heights(2, 0, 0, v_w, v_h) r LOOP
    h[y * v_w + x + 1] := f;
  END LOOP;
  FOR x, y, kx IN SELECT g.x, g.y, CASE WHEN g.kind = 'sea' THEN -1 WHEN g.kind IN ('desert', 'dunes', 'salt') THEN v_desert ELSE 1 END FROM public.rpg_map_ground_of(2, 0, 0, v_w, v_h) g LOOP
    land[y * v_w + x + 1] := kx >= 0; wt[y * v_w + x + 1] := greatest(kx, 0);
  END LOOP;
  fill := array_fill(NULL::double precision, ARRAY[v_n]); dn := array_fill(0, ARRAY[v_n]); done := array_fill(false, ARRAY[v_n]);

  -- seed the flood: every land cell beside the sea, draining to its lowest sea neighbour
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := 0;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
      nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
      IF NOT land[nb] AND (d = 0 OR h[nb] < h[d]) THEN d := nb; END IF;
    END LOOP; END LOOP;
    IF d > 0 THEN
      -- push (h[c], c, d) onto the heap (lowest height first, then lowest cell number)
      hn := hn + 1; hk[hn] := h[c]; hc[hn] := c; hd[hn] := d; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        f := hk[i]; hk[i] := hk[j]; hk[j] := f; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END IF;
  END LOOP;

  -- the flood, lowest first
  WHILE hn > 0 LOOP
    f := hk[1]; c := hc[1]; d := hd[1];
    hk[1] := hk[hn]; hc[1] := hc[hn]; hd[1] := hd[hn]; hn := hn - 1; i := 1;
    LOOP
      j := 2 * i; EXIT WHEN j > hn;
      IF j < hn AND (hk[j + 1] < hk[j] OR (hk[j + 1] = hk[j] AND hc[j + 1] < hc[j])) THEN j := j + 1; END IF;
      EXIT WHEN hk[i] < hk[j] OR (hk[i] = hk[j] AND hc[i] <= hc[j]);
      t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
    END LOOP;
    CONTINUE WHEN done[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w;
    -- two flows never cross corner to corner: where the water of c would run to a corner neighbour past two cells
    -- that already drain one into the other, it runs into the lower of those two instead
    IF land[d] AND (d - 1) / v_w <> y AND (d - 1) % v_w <> x THEN
      e := y * v_w + (d - 1) % v_w + 1;           -- beside c east or west, on c's row
      p := (d - 1) / v_w * v_w + x + 1;           -- beside c north or south, in c's column
      IF done[e] AND dn[e] = p THEN d := p; ELSIF done[p] AND dn[p] = e THEN d := e; END IF;
    END IF;
    done[c] := true; fill[c] := f; dn[c] := d; ord := ord || c;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
      nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
      CONTINUE WHEN NOT land[nb] OR done[nb];
      hn := hn + 1; hk[hn] := greatest(h[nb], f + v_eps); hc[hn] := nb; hd[hn] := c; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END LOOP; END LOOP;
  END LOOP;

  -- the water each cell gathers, from the top of the flood down
  acc := wt;
  FOR i IN REVERSE coalesce(array_length(ord, 1), 0) .. 1 LOOP
    c := ord[i]; d := dn[c];
    IF land[d] THEN acc[d] := acc[d] + acc[c]; END IF;
  END LOOP;

  -- the hollows: cells the flood filled above their own ground, joined by their eight neighbours; the deep ones are great lakes
  lk := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR lk[c] <> 0 OR fill[c] <= h[c] + 1e-3;
    ng := ng + 1; st := ARRAY[c]; grp := '{}'; lk[c] := ng; f := 0;
    WHILE coalesce(array_length(st, 1), 0) > 0 LOOP
      p := st[array_length(st, 1)]; st := st[1:array_length(st, 1) - 1]; grp := grp || p; f := greatest(f, fill[p] - h[p]);
      x := (p - 1) % v_w; y := (p - 1) / v_w;
      FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
        CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
        nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
        IF land[nb] AND lk[nb] = 0 AND fill[nb] > h[nb] + 1e-3 THEN lk[nb] := ng; st := st || nb; END IF;
      END LOOP; END LOOP;
    END LOOP;
    gdeep[ng] := f;
    IF f >= v_hollow THEN
      v_lakes := v_lakes || jsonb_build_array((SELECT jsonb_build_array(max(fill[g]))
                                               || jsonb_agg(jsonb_build_array((g - 1) % v_w, (g - 1) / v_w) ORDER BY g)
                                                 FROM unnest(grp) AS g));
    END IF;
  END LOOP;
  -- only the deep hollows stay lakes
  FOR c IN 1 .. v_n LOOP
    IF lk[c] > 0 AND gdeep[lk[c]] < v_hollow THEN lk[c] := 0; END IF;
  END LOOP;

  -- the rivers: great rivers where enough water gathers; the way out of every great lake down to the sea or a great river
  isriv := array_fill(false, ARRAY[v_n]); kk := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    IF land[c] AND lk[c] = 0 AND acc[c] >= v_great THEN isriv[c] := true; END IF;
  END LOOP;
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR lk[c] = 0;
    d := dn[c];
    CONTINUE WHEN NOT land[d] OR lk[d] = lk[c];
    -- c is the lake's last cell: its water leaves for d; follow it down
    WHILE land[d] AND lk[d] = 0 AND NOT (isriv[d] AND acc[d] >= v_great) LOOP
      isriv[d] := true; d := dn[d];
    END LOOP;
  END LOOP;
  FOR c IN 1 .. v_n LOOP
    IF isriv[c] THEN kk[c] := CASE WHEN acc[c] >= v_great THEN 2 ELSE 3 END; END IF;
  END LOOP;

  -- the main water into each river cell: the river (or the lake) upstream that brings it the most
  up := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR NOT (isriv[c] OR lk[c] > 0);
    d := dn[c];
    CONTINUE WHEN NOT land[d] OR NOT isriv[d];
    IF up[d] = 0 OR acc[c] > acc[up[d]] OR (acc[c] = acc[up[d]] AND c < up[d]) THEN up[d] := c; END IF;
  END LOOP;

  -- one bend a river cell: from the middle between it and its main water, past its middle, to the middle between it and
  -- the cell below; a river rises at the middle of its first cell; one leaving a lake starts in the lake
  v_main := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT isriv[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := dn[c];
    kx := x + 0.5 + public.rpg_map_wrap_step(((d - 1) % v_w) - x, v_w) / 2.0; ky := y + 0.5 + (((d - 1) / v_w) - y) / 2.0;
    p := up[c];
    v_id := v_id + 1; v_main[c] := v_id;
    IF p = 0 THEN
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, x + 0.5, y + 0.5, (x + 0.5 + kx) / 2, (y + 0.5 + ky) / 2, kx, ky, kk[c], kk[c], 1, 0));
    ELSE
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id,
                    x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) / 2.0, y + 0.5 + (((p - 1) / v_w) - y) / 2.0,
                    x + 0.5, y + 0.5, kx, ky, CASE WHEN lk[p] > 0 THEN kk[c] ELSE kk[p] END, kk[c], 0, 0));
      IF lk[p] > 0 THEN
        -- the lead from the middle of the lake's last cell out to its edge
        v_id := v_id + 1;
        v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id,
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w), y + 0.5 + (((p - 1) / v_w) - y),
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) * 0.75, y + 0.5 + (((p - 1) / v_w) - y) * 0.75,
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) / 2.0, y + 0.5 + (((p - 1) / v_w) - y) / 2.0,
                      kk[c], kk[c], 1, 0));
      END IF;
    END IF;
  END LOOP;
  -- the end of each river cell's bend: on into the sea or a lake to the middle of the cell below, or into the bigger
  -- river at the middle of that river's own bend where it is not the main water there
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT isriv[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := dn[c];
    dx := public.rpg_map_wrap_step(((d - 1) % v_w) - x, v_w); dy := ((d - 1) / v_w) - y;
    kx := x + 0.5 + dx / 2.0; ky := y + 0.5 + dy / 2.0;
    IF NOT land[d] OR lk[d] > 0 THEN
      v_id := v_id + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, kx, ky, x + 0.5 + dx * 0.75, y + 0.5 + dy * 0.75, x + 0.5 + dx, y + 0.5 + dy, kk[c], kk[c], 0, 0));
    ELSIF up[d] <> c THEN
      -- the middle of the bend of d, as seen from c (d's own numbers shifted by the step from c)
      SELECT 0.25 * ((z.e2 ->> 1)::double precision) + 0.5 * ((z.e2 ->> 3)::double precision) + 0.25 * ((z.e2 ->> 5)::double precision),
             0.25 * ((z.e2 ->> 2)::double precision) + 0.5 * ((z.e2 ->> 4)::double precision) + 0.25 * ((z.e2 ->> 6)::double precision)
        INTO f, t FROM (SELECT v_pieces -> (v_main[d] - 1) AS e2) z;
      -- shift d's numbers into c's side of the world edge
      ix := (x + dx) - ((d - 1) % v_w);
      f := f + ix;
      -- the bend leaves c the way c's own bend arrives (so the line turns smoothly), half the way to that middle
      kx := sqrt(power(f - (x + 0.5 + dx / 2.0), 2) + power(t - (y + 0.5 + dy / 2.0), 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_id := v_id + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, x + 0.5 + dx / 2.0, y + 0.5 + dy / 2.0,
                    x + 0.5 + dx / 2.0 + dx * kx, y + 0.5 + dy / 2.0 + dy * kx, f, t, kk[c], kk[c], 0, v_main[d]));
    END IF;
  END LOOP;
  -- (step 14f2) every Continent cell's own numbers, so each cell's rivers can be found inside it (rpg_map_drain_cell):
  -- dn = the cell its water runs to (cell number y * 144 + x), -1 for the sea; acc = the water it gathers (Continent
  -- cells, a desert counting map_drain_desert), -1 for the sea; ch = 2 or 3 where a downhill river runs through it, 9
  -- where it is a great lake, else 0; wt = the water each of its cells sends on (1, a desert map_drain_desert)
  RETURN jsonb_build_object('pieces', v_pieces, 'lakes', v_lakes,
    'dn', (SELECT jsonb_agg(CASE WHEN land[g] THEN dn[g] - 1 ELSE -1 END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'acc', (SELECT jsonb_agg(CASE WHEN land[g] THEN round(acc[g]::numeric, 2) ELSE -1 END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'ch', (SELECT jsonb_agg(CASE WHEN NOT land[g] THEN 0 WHEN lk[g] > 0 THEN 9 ELSE kk[g] END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'wt', (SELECT jsonb_agg(wt[g] ORDER BY g) FROM generate_series(1, v_n) AS g));
END;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_map_icons()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The map symbols a place card may name as its icon. The page holds the drawing for each name, in two styles: a
-- fantasy-map symbol for the grids from the world down to a district, and a view from above for the battle grid.
-- A new symbol = a drawing in the page (MAP_ART in Roleplaying.jsx) and its name added here. The grounds of the
-- climates (grassy plains, pine forest, jungle, desert, tundra, snow and ice, swamp; savanna and scrub, sand dunes,
-- salt flats, bog) are symbols too. So are
-- a town and a city (step 8: the villages, towns and cities that grow on the land, rpg_map_towns), a great city
-- (step 12a), and the landmarks (step 12b, rpg_map_landmark_kinds): a peak, a castle, a tower, a stone circle, a
-- standing stone, a boulder and a cairn (ruins was already one), and the places to go into (step 12c,
-- rpg_map_location_kinds): a cave, a mine, a shrine, a camp and a hut.
SELECT ARRAY['forest', 'hills', 'mountains', 'village', 'road', 'lair', 'ruins', 'valley', 'fog', 'thorns',
             'plains', 'pine', 'jungle', 'desert', 'tundra', 'ice', 'swamp', 'savanna', 'dunes', 'salt', 'bog', 'town', 'city', 'great_city',
             'peak', 'castle', 'tower', 'stones', 'stone', 'rock', 'cairn', 'cave', 'mine', 'shrine', 'camp', 'hut'];
$function$;
UPDATE public.rpg_rules SET body = $rb$The world map is made of the same squares a fight is played on, each 3 feet 8 inches across, and the world is the size of the Earth: 24,901 miles around. The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board. Each cell of a grid shows the ground most of the land inside it holds, so zooming in keeps every coast, mountain chain, wood and climate where it was, only finer.

On a journey everyone takes turns on one clock, the same clock a fight uses. A tick is a sixth of a second, so an hour is 21,600 ticks.

On its turn a piece walks toward any square the game master picks, the whole way in one go: straight, or along the roads (see below). Every square it steps into takes 5 ticks at Speed 10 plus the share of time that square adds, faster or slower by Speed like everything else. The ranges are the same as on a fight board: open land +0% to +10%, forest +20% to +150% with thickets at +400%, mountains +200% to +500%, and so on. A walk longer than about 7 miles counts each 1.2-mile stretch as the average square of its ground. The climate shapes the land: snow and ice, then tundra, toward the poles; pine forest in the cold; desert where it is driest, with seas of sand dunes in its driest parts and salt flats in its lowest ground; grassy plains where it is dry; savanna and scrub where it is warm and a little drier than jungle; jungle where it is hot and wet; swamp in wet lowlands, and bog where those lowlands are cold. Savanna and scrub is +5% to +50%, sand dunes +80% to +150%, salt flats +0% to +15%, bog +50% to +150%. Every zoom of the map adds its own small woods, clearings and patches of rough ground; rough ground is hills, +25% to +75%. One mountain square in twenty is a cliff, climbed with a Climbing roll (see Climbing). Where a stream, river or great river runs through hills or mountains it has cut a gorge. Its walls are cliffs from the water's edge to the rim, climbed square by square like any cliff (see Climbing): 55 degrees in hills, 70 in mountains. A stream's gorge is 8 m deep in hills and 24 m in mountains, a river's 25 m and 75 m, a great river's 40 m and 120 m; brooks cut none. A road crosses on its bridge.
*At Speed 10 a mile of savanna, +27.5% on average, is 1,439 x 5 x 1.275 = 9,174 ticks, about 25 minutes; a mile of sand dunes, +115%, is 15,469 ticks, about 43 minutes; a mile of salt flat, +7.5%, is 7,735 ticks, about 21 minutes; a mile of bog, +100%, is 14,390 ticks, 40 minutes.*
*A river gorge in hills has walls about 16 squares wide each side: each square climbs 1.6 m, Climbing against 3.6, +2,199%, so at Speed 10 it takes 115 ticks, about 5 minutes a wall. In mountains a wall is about 24 squares, 3.1 m a square, Climbing against 6.7, +4,323%: about 15 minutes a wall.*
*A mile is 1,439 squares. At Speed 10 a mile of open land, +5% on average, is 1,439 x 5 x 1.05 = 7,555 ticks, 21 minutes: about 2.9 miles an hour. Zaboo (Speed 5) takes 7,555 x 20 / 15 = 10,073 ticks, 28 minutes. Forest averages +124% with its thickets, so a mile of it takes 45 minutes at Speed 10; mountains average +350%, 1 hour 30 minutes.*

Rivers and lakes run through the land: great rivers 400 m wide and 8 m deep in the middle, rivers 60 m and 3 m, streams 10 m and 0.8 m, brooks 2 m and a quarter of a metre; lakes and ponds cover about 4 in 100 of the land. They sit in the hollows of the land, filled up to the lowest point of their rim, where the water runs on: big lakes in the hollows of the Country grid, lakes in those of the Region grid, ponds in those of the City grid, and a river that reaches one ends at its shore. *Of every 100 square miles of land about 1.5 lie under big lakes, 1.2 under lakes and 1 under ponds: 3.7 in all, as on Earth.* A hollow too shallow for a lake is a marsh: its ground is swamp, and a river runs on through it. *A marsh square adds +80% to +200% time like any swamp: 5 × 1.8 = 9 to 5 × 3 = 15 ticks at Speed 10, against 5 to 5.5 on open land.* Rivers wind: at every scale, from the smallest bends a river of its width makes (11 widths long) up to the cells of its own grid, the line swings sideways by about a quarter of that scale, so a river wanders at every zoom and the zoomed-in river lies where the zoomed-out one was drawn. Rivers never cross: a smaller river ends where it meets a bigger one, joining it from either bank, the way a stream runs into a river and a river into a great river. Great rivers run downhill: the water of every Continent cell runs to the neighbour the land lets it reach the sea by, gathering as it goes, and a great river flows wherever the water of about half a million square kilometres (6 Continent cells) has gathered, rising on high ground and ending in the sea or a great lake. A hollow in the land at least 3 deep holds a great lake, full to its rim; it drains on by a river from the lowest point of its rim. *A great lake filling a mountain hollow 170 miles across is up to 150 m deep; the river out of it leaves at the low point of its rim and runs on to the sea.* Rivers run downhill too: inside each Continent cell the water of every Country cell (about 23 km across) runs down to the sea, a great river, or the low crossing where the cell's water goes on to the next cell, and a river flows wherever the water of 20 Country cells, about 11,000 square kilometres, has gathered; smaller rivers join bigger ones like the branches of a tree. *20 Country cells of 538 square kilometres each is about 10,800 square kilometres, a square about 104 km a side: the land one river 60 m wide drains.* Streams and brooks are found the same way, one grid finer each: inside each Country cell a stream flows wherever the water of 82 Region cells, about 300 square kilometres, has gathered, and inside each Region cell a brook flows wherever the water of 470 City cells, about 12 square kilometres, has. *A river's width grows with the square root of the land it drains: a river 60 m wide is 6 times as wide as a stream 10 m wide, so it drains 6 x 6 = 36 times the land, and 11,000 / 36 is about 300 square kilometres (82 Region cells of 3.7 square kilometres each). A brook 2 m wide is a fifth of a stream, so it drains 1/25 of that: about 12 square kilometres (470 City cells of 0.026 square kilometres each).* A river narrower than a cell is drawn as a line through that cell; it fills cells only where it is at least as wide as they are.
*A 60 m river swings about 2 miles either way over its biggest bends, 7 miles long, and about 160 m over its smallest, 660 m long.* A square of water adds time by its depth, the same as on a fight board, and deeper water is drawn darker. Water deeper than 1.2 m is swum, not waded: the walk swims across it, rolling Swimming every few seconds (see Swimming).
*A knee-deep ford square takes 5 × 1.5 = 7.5 base ticks, 8 ticks at Speed 10. Wading across a 10 m stream, 9 squares, takes about 72 ticks, 12 seconds.*

People live in villages, towns and cities, spread over the land the way farming country was in medieval England. In good open land there is a village of 100 to 400 people about every 2 miles, a market town of 500 to 5,000 about every 9, a city of 8,000 to 16,000 about every 110, and a great city of 20,000 to 200,000 about every 330 (London had perhaps 80,000 people c. 1300, Paris about 200,000 in 1328). Forest holds half as many, hills a little more than half; pine forest, jungle, mountains and swamp few; desert and tundra almost none; snow and ice none; and none stand inside a haunt or any other place with ground of its own. A great city needs good land twice over, for its site and for the farms that feed it, so forest has a quarter as many, hills about a third, and rough country almost none; it never stands in the sea. The Continent grid shows the great cities, the Country grid the cities too, the Region grid all four, and closer grids their streets and yards, +0% to +10% time a square like open land. On the battle grid a town or city has a market place at its middle, its main road widened to 16 to 40 m across for 60 to 220 m, and streets running behind the main road with lanes across them, as much street as its households need frontage for: a city of 12,000 people (2,667 households of 4.5) on plots of 1.25 perches needs 2,667 × 6.3 m ÷ 2 = 8.4 km of street, both sides lined; less the roads and the market place already there. The streets lie 50 m apart at the middle and further apart toward the edge (up to 100 m), as the plots near the market filled first. Streets (about 5 m wide) and the market place are paved and walked like a road; lanes are about 2.8 m wide; a street stops at the water, and a church may stand across a street or a lane, which then ends at its walls. Houses stand along the roads, the market place and the streets, one household of 4.5 people to a house, in plots that share both sides of the streets among the households, within the widths medieval surveyors laid out: a village toft 2 to 4 perches (10 to 20 m), a town burgage 1.5 to 2.5 perches, a city plot 1 to 1.5 (a perch is 5 m). A village house is 4 to 5.5 m wide and 2 to 4 bays long (a bay is 4.6 m), one storey under thatch; a town house fills its plot and runs 2 to 3 bays back, two storeys under clay tiles; a city house has two or three, a great city house three or four. A village whose middle only one lane reaches has its street run on through the middle. The District grid shows the same buildings as the battle grids under it. Beside the houses: about half the villages have their own church on the plot at their middle, and six village tofts in ten have a barn behind the house (2 to 3 bays long, 5.5 to 7 m wide); every town and city has its main church at its middle and a parish church for every 1,200 people in a town or 600 in a city (a town of 3,600 people has 3 churches, a city of 12,000 has 20); one town or city plot in ten holds a hall house set along the street across two plots, and six town houses in ten have a back range running back from one side. A parish church lies east to west: a tower 5 to 8 m square and 15 to 30 m high at the west end, a nave 15 to 25 m long (6 to 9 m wide in a village, 12 to 18 m with aisles in a town or city) and a chancel 8 to 14 m long to the east. A great city also has a cathedral in its own close off the streets: a nave 60 to 90 m long, transepts across it, a choir to the east, a tower 40 to 60 m high over the crossing and two at the west front. Roofs are thatch in nine villages in ten; in towns and cities mostly clay tile, with stone slate and some thatch; churches are roofed in lead, stone slate or tile. On the battle grid a building is seen inside. Its outer walls are climbed (see Climbing: a house 2.6 m to its eaves is a 2.6 m sheer wall, Climbing against 10; a church tower 25 m high a 25 m wall), and so are the walls inside a house, one storey high; its doors and floors are walked like the ground. A house whose long side faces its street has a front and a back door opposite each other one bay in from one end (a 3-bay house, 13.8 m long, has them 4.6 m from that end); a house whose gable faces the street has a door in each end beside its passage. A house of 2 bays has a cross wall in its middle, of 3 or more a cross wall one bay in from each end with the hall between, each with a doorway in its middle. A barn has cart doors 2.4 m wide in the middle of both long sides; a church a south and a north door near the west end of its nave; a cathedral a great west door and a door at each end of its transepts. A door is 1.2 m wide. A house of two storeys or more has its stair along the inside of its back wall at the end away from its cross passage, two squares long, and each floor up has the same walls, its doors walls there; the map shows each floor with ▴ ▾ above it, the ground below blurred more the higher the floor. About one house in five with a stair has a cellar under its main part, its stair going on down: one open room, walls all round, shown below the ground floor with the street above it blurred. A church tower has a door in its outer face and its stair in a corner; a great tower (walls 3 m thick) and a watchtower (1.5 m) a door on one side and the stair across from it, where they are wide enough to be hollow; a castle keep (walls 4 m in a fortress, 3.5 m in a castle, 2 m in a tower house) a door facing the gate and its stair in the far corner. A 38 m great tower has 9 floors, a 31 m keep 4.
*A storey is 2.4 to 2.9 m high, so a stair climbs about 2.6 m in its two squares (2.2 m): steep, about 50 degrees.*
*A village of 250 people covers about 12 hectares, a quarter of a mile across. A town of 2,000 is about a third of a mile across, a city of 12,000 about two thirds of a mile. A great city of 100,000, at 230 people a hectare (a bigger city is more crowded), covers 435 hectares, about a mile and a half across.*

Roads join the places people live, from one to the next, and wander on the way: a road leaves each place straight and bends about the line between them, its biggest bends (up to 3.6 miles long) swinging a highway sideways by 6 in 100 of their length, a road 9 and a lane 12, and every bend half as long swinging less for its length, so a road is smoothest close up and the zoomed-in road lies where the zoomed-out one was drawn. The houses of a village, town or city line the road where it truly runs.
*A lane between villages 1.8 miles apart swings about 200 m either way; a highway between towns 7 miles apart about 350 m, 600 m at most.* A highway 6.5 m wide (about 6 squares, the width of the main Roman roads) runs from each city to the cities around it, by way of the market towns between; a road 4.9 m wide (about 4 squares, room for two carts to pass) joins each town to the towns around it; and a lane 2.4 m wide (about 2 squares, one cart) runs from each village toward its market town, as far as the next place where people live. Roads cross lakes on a causeway and rivers on a bridge or through a ford, but never the sea, and keep out of any place with rough ground of its own, like the Old Forest; through an open place they run on its own ground. Every highway bridges every river it meets; a road fords about one river or stream in three and a lane two in three, one call a stretch, so a lane that fords a river fords it at every crossing; a great river is always bridged and a brook needs only a plank. A ford is knee-deep (0.5 m, +50% a square) from bank to bank and 9 m along the river; a bridge is road over the water. Rivers and streams have planned fords off the roads too, about one in twelve City cells they run through, shown from the City grid down (streams from the District grid): a walk sent through one wades where it would swim. A square of road adds +0% to +10% time whatever ground it crosses, except a mountain road, which keeps three fifths of the time of mountains, +80% to +260%; snow and ice stay snow and ice. The Country grid shows the highways, the closer grids all three.
*At Speed 10 a mile of road takes 21 minutes, like open land, and a mile of mountain road 54 minutes instead of 1 hour 30.*

A walk keeps to the roads where they are quicker by its count: every step off a road counts as 5/3 of a step on one (walking off a path takes that much longer, Tobler 1993), and the walk takes the way with the fewest. It plans its way up to about 14 miles ahead; when the end lies farther and the roads lead on, it stops where its plan ends and can carry on from there next turn.
*A town 8 miles away across forest is 6 hours straight at Speed 10; by a road 10 miles long, 3 hours 30.*

Nobody walks into the sea or into water too rough to swim, and a walk never ends in deep water. A walk that reaches either stops on the last dry square. A walk also stops one square short of anyone standing in its way.

A piece walks at most 8 hours a day, then camps 16 hours where it stands. If the day runs out on the way, it camps there and can carry on next turn. A piece can also camp on its turn instead of walking, which starts its walking day fresh.
*At Speed 10, 8 hours of open land is about 23 miles.*

Creatures live in their haunts. For every full hour a piece walks inside a haunt, the site rolls a d100: on 15 or less a creature of that haunt appears 10 squares (37 feet) away, the walk stops and the fight is on, on that ground.
*Over 8 hours in a haunt that is a fight on about 3 days in 4: the chance of no creature all day is 0.85 multiplied by itself 8 times, 0.27.*

While a creature still in the fight stands within 164 squares (600 feet, a longbow shot), a piece moves on the fight board, a turn at a time, instead of walking the map.

Landmarks stand out on the land and are steered by from far off: lone peaks, castles, ruins, towers, stone circles, standing stones, boulders and cairns, as big as real ones are. The World grid shows the greatest few, a great peak rising 15,000 to 20,000 feet or the ruins of a city miles across; every grid shows its own and all those of the grids above it: the Continent grid peaks and fortresses, the Country grid mountains, castles and great towers, the Region grid hills, tower houses, ruined chapels, watchtowers and stone circles, the City grid crags, mottes, ruined crofts, beacons and great standing stones, the District grid boulders, broken walls, standing stones and cairns. Peaks stand on mountains and hills, and a great peak sometimes alone on open land, as the great volcanoes do; castles on farmland and hills; ruins anywhere dry; none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own. On the battle grid they stand as they are: a castle is a keep inside a curtain wall with one gate, a ruin is the broken walls of its rooms, a stone circle a ring of stones about 4 m apart; their walls, towers, stones and boulders are climbed like the wall of a house (see Climbing), a cairn or the side of a motte like a slope of rock, and a walk goes round them. A lone peak is the mountain itself.
*A castle keep 100 feet tall is made out from about 13 miles. Its top shows over the horizon from 12.3 miles (the square root of 2 × the radius of the world × its 30.5 m), on top of the 2.7 miles of a person's own horizon, 15 miles; but the eye makes out only what spans 5 minutes of arc, 30.5 m ÷ 0.00145 = 21 km, 13 miles, the nearer of the two. A standing stone 2 m tall is made out from about 4,500 feet, a peak rising 13,000 feet from about 140 miles. Karen (Climbing 7) needs 59 to get up the wall of a tower house, 5.4 m and sheer; a slip drops her 5.4 m for 6 damage.*

Places to go into are smaller: caves, mines, shrines, camps and huts, rolled where no landmark stands. The Region grid shows great caves, mine workings and war camps, the City grid caves, mines, shrines, camps and huts, the District grid hollows, wayside shrines, campsites and huts. Caves and mines lie in mountains and hills, camps in woods and on open land, shrines and huts on any dry ground. On the battle grid each has its way in: a hut or a shrine its door, a cave or a mine its mouth, a war camp its gate. Their walls, rock, palisades and tents are climbed like the wall of a house, a spoil heap like a slope of rock; the floor inside is walked like the ground.
*A hut 6 m across and 4 m tall is 5 squares wide: a ring of wall to the eaves, 2.4 m and sheer (Climbing against 10), round 5 squares of floor with the hearth in the middle, and one square of door.*

Under the ground runs a world of its own. Cave country, 3 in 10 of the land (twice Earth's share of cave rock), holds chambers 100 to 9,800 feet down, about one every 2.4 miles, joined into systems hundreds of miles long. Below it all lie the Deeps, 13,000 to 26,000 feet below the sea: a great hall about every 86 miles, most of them joined into one network that runs round the world and under the seas. Caves and mines lead in: a great cave runs up to 3 miles into the hill, mine workings go down a shaft as deep as 13,000 feet; most great caves and some caves and mines break into cave country, and a few reach the Deeps. The Underground switch on the map shows what lies under a grid; your group sees the passage of a cave or mine once it has found it.
*A chamber's depth is rolled on a doubling scale between 100 and 9,800 feet, as many shallow as deep: a roll of 50 puts it about 960 feet down.*

To go under the ground, a piece stands at a cave or a mine and goes in. Under the ground it walks one passage at a time to where the passage leads: on through the Deeps at a good pace (+25% time), along cave passages by crawling and scrambling (+250%: cavers make about half a mile an hour), through the galleries of a mine (+50%), squeezing through where a cave or mine breaks into cave country or the Deeps (+400%), and up or down a shaft at 1,000 feet an hour. The walking day is the same as on the surface: 8 hours, then 16 to camp, in the passage if need be. From below, the ways up into caves and mines are hidden until someone searches the chamber or great hall (1 hour) or has walked them. A piece comes up only at the mouth of a cave or a mine.
*At Speed 10 the 2,440-foot passage of Storm Grotto takes about 32 minutes, and the 1.26-mile squeeze from its far end into cave country about 2 hours 6 minutes.*

Under the ground there is a battle grid too, square for square like the one on the surface. A passage winds, widens and narrows as it goes: a passage of the Deeps is 50 to 300 feet wide, a cave passage 5 to 26 feet, a mine gallery 7 to 16 feet, a squeeze 2 to 5 feet (never less than a square). Chambers of cave country are 40 to 400 feet across, the great halls of the Deeps 1,000 to 4,900 feet. Everything else is solid rock: no way in. Floors cost time like ground on the surface: the Deeps +10% to +40%, cave floor +100% to +357% with fallen rock (+400%) on one square in eight, mine floor +20% to +80%, a squeeze +300% to +500%; a pool is waded by its depth, a column of stone is no way through, a shaft is climbed. Creatures are met under the ground the same way as in their haunts on the surface: every hour walked in a passage where a creature lives, a roll of 15 or less meets one, and the fight is on, on the battle grid under the ground.
*The average square of a floor is what a walk under the ground takes: cave floor is 0.875 x (100 + 357) / 2 + 0.125 x 400 = 250%, so at Speed 10 a square of it takes 5 x 3.5 = 17.5 ticks, about 3 seconds.*

The map shows what your group has found: everything within 2.7 miles each way of where any of you walked, the distance to the horizon for a person's eyes. The rest stays dark until someone goes there or knows the place. A landmark shows from as far off as it can be made out, even over ground not found yet.
*A 20-mile walk shows a strip about 25 miles long and 5.4 miles wide.*

Weather comes and goes over every 14-mile patch of land, worked out every 3 hours of the journey. It adds time to every square you walk, on top of the ground: fog and rain +10%, a thunderstorm +25%, snow +30%, a dust storm +50%, a blizzard +100%. It slows swimming and climbing a cliff too, on a walk and in a fight. Weather also cuts how far you see, so less of the map opens up as you walk: rain about 1.9 miles each way, a thunderstorm or snow about half a mile, fog about a third of a mile, a blizzard a quarter mile. Clear or cloudy weather lets you see the full 2.7 miles.
*A 20-mile walk in fog shows a strip about 20.6 miles long and 0.62 miles wide, instead of 25.4 by 5.4 in clear weather.*
*Open land at +5% takes 5 × 1.05 = 5.25 ticks a square at Speed 10. In snow it is +35%: 5 × 1.35 = 6.75 ticks, so a 20-mile walk of 6 h 40 min takes about 8 h 34 min.*
In a fight outdoors the weather counts too (not under the ground or inside a building). Every step takes the weather's extra time on top of the ground's, as on a walk, swimming and climbing included. Rain, a thunderstorm, snow or a blizzard soak what would burn, so a square set alight does not catch. A dust storm keeps a fire burning a round longer, 4 rounds instead of 3. A thunderstorm, a blizzard or a dust storm blows shots off their mark: a blow from 2 squares away or more that lands is carried wide when its die is in the lower half of the dice that land, the same as half cover.
*In a blizzard a plain square at +5% takes 5 × 2.05 = 10.25 ticks at Speed 10 instead of 5.25, so a turn's 20 ticks of moving cover 1 such square instead of 3. A longbow needing 50 in a thunderstorm lands on 50 to 100, but 50 to 74 are carried wide; only 75 or more go on to the Block gate.*$rb$, updated_at = now() WHERE key = 'world_map';

