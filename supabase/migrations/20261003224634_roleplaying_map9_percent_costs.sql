-- Step 6 (Peter 2026-10-03 21:45 + 22:05, 1B): movement cost is a percent per square that matches real walking
-- research. Every kind of ground has a range; every square has its own spot inside its ground's range, harder squares
-- drawn darker. A square takes move_ticks (5) at Speed 10 times (1 + its percent / 100).

ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS place_penalty_high integer;
COMMENT ON COLUMN public.rpg_creatures.place_penalty IS 'Place cards with ground of their own: the least percent of time a square of this place adds to cross it (0 = no slower than plain ground). Empty = the place only names the land.';
COMMENT ON COLUMN public.rpg_creatures.place_penalty_high IS 'Place cards with ground of their own: the most percent of time a square of this place adds to cross it. Each square sits somewhere from place_penalty to this. Empty = the same as place_penalty.';

-- The ranges, from real walking studies (Peter 2026-10-03 22:05, 1B): orienteering runnability classes (ISOM 2017:
-- slow running 60-80% of normal speed, difficult 20-60%, very difficult under 20%) and Soule & Goldman 1972 terrain
-- factors. A setting map_<ground>_penalty holds the least percent, map_<ground>_penalty_high the most.
UPDATE public.rpg_settings SET value = 20, label = 'Forest: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_forest_penalty';
UPDATE public.rpg_settings SET value = 20, label = 'Pine forest: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_pine_penalty';
UPDATE public.rpg_settings SET value = 100, label = 'Jungle: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_jungle_penalty';
UPDATE public.rpg_settings SET value = 25, label = 'Hills: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_hills_penalty';
UPDATE public.rpg_settings SET value = 200, label = 'Mountains: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_mountain_penalty';
UPDATE public.rpg_settings SET value = 10, label = 'Desert: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_desert_penalty';
UPDATE public.rpg_settings SET value = 20, label = 'Tundra: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_tundra_penalty';
UPDATE public.rpg_settings SET value = 50, label = 'Snow and ice: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_ice_penalty';
UPDATE public.rpg_settings SET value = 80, label = 'Swamp: least percent of time a square adds to cross it' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_swamp_penalty';
UPDATE public.rpg_settings SET value = 300, label = 'Percent of time a burning square adds to step into it, for everyone' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'burn_cost';
UPDATE public.rpg_settings SET label = 'Base ticks to step into a square that adds no time (+0%)' WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'move_ticks';
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_forest_penalty_high', 150::numeric, 'Forest: most percent of time a square adds to cross it'),
               ('map_pine_penalty_high', 150, 'Pine forest: most percent of time a square adds to cross it'),
               ('map_jungle_penalty_high', 300, 'Jungle: most percent of time a square adds to cross it'),
               ('map_hills_penalty_high', 75, 'Hills: most percent of time a square adds to cross it'),
               ('map_mountain_penalty_high', 500, 'Mountains: most percent of time a square adds to cross it'),
               ('map_desert_penalty_high', 110, 'Desert: most percent of time a square adds to cross it'),
               ('map_tundra_penalty_high', 80, 'Tundra: most percent of time a square adds to cross it'),
               ('map_ice_penalty_high', 300, 'Snow and ice: most percent of time a square adds to cross it'),
               ('map_swamp_penalty_high', 200, 'Swamp: most percent of time a square adds to cross it'),
               ('map_land_penalty', 0, 'Open land: least percent of time a square adds to cross it'),
               ('map_land_penalty_high', 10, 'Open land: most percent of time a square adds to cross it'),
               ('map_plains_penalty', 0, 'Grassy plains: least percent of time a square adds to cross it'),
               ('map_plains_penalty_high', 10, 'Grassy plains: most percent of time a square adds to cross it'),
               ('map_thicket_penalty', 400, 'Thickets of brambles in forest and pine forest: percent of time a square adds to cross it'),
               ('map_thicket_share', 0.125, 'Share of forest and pine forest squares that are thickets: one in eight, the same share as clearings'),
               ('map_hard_from', 5, 'The grid (5 = City) from which squares differ inside their ground: patches from about half a mile down to one square')) AS n(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = n.key);

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates), in the order
-- the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block detail; the page reads
-- the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent of time a square of it
-- adds to cross it (the most is the same key with _high; rpg_map_band; the sea = no entry), and whether it is forest
-- (it has trees: it burns and hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', 'map_land_penalty', false),
               (3, 'plains', 'Grassy plains', 'g', 'map_plains_penalty', false),
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

CREATE OR REPLACE FUNCTION public.rpg_map_band(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(low integer, high integer, thicket integer, share double precision, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The range of a kind of ground, the one home of it (Peter 2026-10-03 22:05, 1B: it must match reality): the least
-- and the most percent of time a square of it adds to cross it, and for forest its thickets. Unnamed ground reads the
-- settings rpg_map_grounds names (forest 20 to 150, thickets 400 for one square in eight); a place reads its card
-- (place_penalty to place_penalty_high), and a place that is forest has thickets too unless its range already reaches
-- them (Bramblemaw's Lair is all thicket, 400). thicket = the percent of a thicket, nothing when it has none; share =
-- how many of its squares are thicket (0 when none). The sea, or a place that only names the land, has no row:
-- nobody walks into the sea.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     t AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_thicket_penalty')::integer AS pct,
                  (SELECT st.value FROM st WHERE st.key = 'map_thicket_share')::double precision AS share),
     b AS (SELECT c.place_penalty AS low, coalesce(c.place_penalty_high, c.place_penalty) AS high,
                  coalesce(c.place_forest, false) AS forest, coalesce(c.place_forest, false) AS thick
             FROM public.rpg_creatures c
            WHERE p_kind = 'place' AND c.id = p_place AND c.place_penalty IS NOT NULL
           UNION ALL
           SELECT (SELECT st.value FROM st WHERE st.key = g.penalty_key)::integer,
                  (SELECT st.value FROM st WHERE st.key = g.penalty_key || '_high')::integer,
                  g.forest, g.kind IN ('forest', 'pine')
             FROM public.rpg_map_grounds() g
            WHERE g.kind = p_kind AND g.penalty_key IS NOT NULL)
SELECT b.low, b.high,
       CASE WHEN b.thick AND b.high < t.pct THEN t.pct END,
       CASE WHEN b.thick AND b.high < t.pct THEN t.share ELSE 0 END,
       b.forest
  FROM b CROSS JOIN t;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_pct(p_low integer, p_high integer, p_thicket integer, p_share double precision, p_hard double precision)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The percent of time one square adds, from its ground's range (rpg_map_band) and how hard it is inside that range
-- (p_hard, 0 to 1, rpg_map_hard): the one home of that sum. The hardest share of a ground with thickets is thicket;
-- the rest spreads evenly from the least to the most. Forest 20 to 150 with thickets 400 for one in eight: hard 0.5
-- is 20 + 130 x 0.5 / 0.875 = 94; hard 0.9 is a thicket, 400. With no hard (a cell too big to see the patches, or a
-- whole ground) it is the average square: (1 - 0.125) x (20 + 150) / 2 + 0.125 x 400 = 124 for forest.
SELECT CASE WHEN p_low IS NULL THEN NULL
            WHEN p_hard IS NULL THEN round((1 - q.s) * (p_low + p_high) / 2.0 + q.s * coalesce(p_thicket, 0))::integer
            WHEN p_thicket IS NOT NULL AND p_hard >= 1 - q.s THEN p_thicket
            ELSE round(p_low + (p_high - p_low) * least(p_hard / (1 - q.s), 1))::integer END
  FROM (SELECT CASE WHEN p_thicket IS NULL THEN 0 ELSE least(greatest(coalesce(p_share, 0), 0), 0.99) END AS s) q;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_ground(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(penalty integer, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What a square of a kind of ground costs on average, in percent of time added to cross it, and whether it is forest:
-- its range (rpg_map_band) read with no hard (rpg_map_pct). Forest averages 124 with its thickets, open land 5,
-- mountains 350. The sea has no percent (nobody walks into it) and is not forest. Read by rpg_map_band_text for the
-- words on the map; a single square reads rpg_map_costs.
SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share, NULL), coalesce(b.forest, false)
  FROM (SELECT 1) AS one
  LEFT JOIN public.rpg_map_band(p_kind, p_place) b ON true;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_hard(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, hard double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How hard each cell of a block is inside its own ground, 0 to 1, worked out when asked and never stored: the one home
-- of it (Peter 2026-10-03 21:45: thicker parts of a forest, deeper water; 22:05 1B). It is the layered rolls of part 6
-- (rpg_map_rolls) from the first layer of the grid map_hard_from (5, the City grid: points about half a mile apart)
-- down to one square, so thick and thin parts come in patches from about half a mile across down to a single square,
-- and a square keeps its spot at every zoom. The roll is turned into a share that is spread evenly from 0 to 1 by the
-- normal curve: hard = (1 + erf(roll / (spread x sqrt 2))) / 2, where spread is how far the rolls stand from 0. That
-- spread comes from how the rolls are made, not from a setting: one d100 less 50.5 stands sqrt(9999 / 12) = 28.9
-- from 0; the eased blend of four of them keeps 26 / 35 of that (the blend weighs the four as (1 - a) and a each way,
-- with a = 3t^2 - 2t^3, and the average of a^2 + (1 - a)^2 is 26 / 35); and the layers add as the square root of the
-- sum of their weights squared (1, 1, 0.6, 0.36 and so on: 2.56 for the nine layers from the City grid down), so
-- the spread is 34.3. A coarser grid reads only its own layers, so its cells sit nearer the middle, the way the
-- average of the squares inside them does. A grid coarser than the City grid has no rows here: its cells are read as
-- the average square of their ground (rpg_map_pct with no hard).
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_hard_from')::integer AS hfrom,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_detail_share')::double precision AS share,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_full_layers')::integer AS full_layers),
     sd AS (SELECT sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0)
                        * sum(CASE WHEN q.r <= cfg.full_layers THEN 1 ELSE power(cfg.share, 2 * (q.r - cfg.full_layers)) END)) AS s
              FROM cfg
             CROSS JOIN LATERAL (SELECT row_number() OVER (ORDER BY y.n) AS r FROM public.rpg_map_layers() y WHERE y.n >= 3 * cfg.hfrom - 2) q
             GROUP BY cfg.hfrom)
SELECT r.x, r.y, 0.5 * (1 + erf(r.value / (sd.s * sqrt(2::double precision))))
  FROM cfg CROSS JOIN sd
 CROSS JOIN LATERAL public.rpg_map_rolls(6, 3 * cfg.hfrom - 2, 1, p_level, p_x0, p_y0, p_cols, p_rows) r;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A block of cells of any grid with what each costs to cross: the cell as rpg_map_cells gives it, how hard it is inside
-- its ground (rpg_map_hard; nothing on a grid coarser than the City grid), and from those the percent of time it adds
-- (rpg_map_pct on its ground's range, rpg_map_band, read once a ground) and whether it is forest. penalty = that
-- percent; nothing for the sea. The one way a block of the map is read with its costs: fight boards
-- (rpg_fight_squares) and the Maps tab (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard), coalesce(b.forest, false), h.hard
  FROM c
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_band_text(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A ground in words, the same for a place card and for unnamed ground: forest or not (a place only; the name of an
-- unnamed ground says it), its range, its thickets and its average square. Forest reads "+20% to +150% time a square,
-- thickets +400%, about +124% on average"; a place that only names the land reads nothing.
SELECT concat_ws(' · ', CASE WHEN p_kind = 'place' AND b.forest THEN 'forest' END,
                 CASE WHEN b.low = b.high THEN '+' || b.low || '% time a square'
                      ELSE '+' || b.low || '% to +' || b.high || '% time a square' END
                 || CASE WHEN b.thicket IS NOT NULL THEN ', thickets +' || b.thicket || '%' ELSE '' END
                 || CASE WHEN b.low <> b.high THEN ', about +' || (SELECT g.penalty FROM public.rpg_map_ground(p_kind, p_place) g) || '% on average' ELSE '' END)
  FROM public.rpg_map_band(p_kind, p_place) b;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_costs on the battle
-- grid: the percent of time each square adds to cross it, and forest; the sea no entry), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map)
SELECT g.x, g.y,
       CASE WHEN m.kind = 'sea' THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       coalesce(m.forest, false) OR i.forest, i.burning, coalesce(m.kind = 'sea', false)
  FROM s CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid, p_budget integer)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square within p_budget of path cost from where they stand, in hundredths of
-- a plain square. Stepping into a square costs 100 plus the percent of time it adds (just 100 for a creature whose
-- card says the ground never slows it: rpg_participant_ignores_penalty), plus burn_cost (300) while the square burns,
-- for everyone; a diagonal step costs the same as a straight one; nobody steps into the sea or into a square someone
-- takes up (rpg_participant_blocks). The first step of a turn may always be taken, whatever it costs, by the one whose
-- turn it is before they have moved (a thicket or a mountain square can take longer than a whole turn of moving; that
-- turn then takes that long). The ground is the world map under the fight (rpg_fight_squares), read once for the block
-- round the fighter. Squares nobody can get to are left out. From C3, briars at +260% on D3 cost 360 to enter, and a
-- plain E3 past them 460; burning briars cost 660, and the Bramblemaw pays 400 there.
DECLARE
  v_p record; v_s record; v_b integer := greatest(coalesce(p_budget, 0), 0); x0 integer; y0 integer; w integer; h integer; n integer;
  d integer[]; pen integer[]; fire integer[]; blk boolean[]; v_ign boolean; v_changed boolean; v_big constant integer := 1000000;
  i integer; j integer; cx integer; cy integer; dx integer; dy integer; nx integer; ny integer; c integer; v_q record; v_o record;
  v_burn integer := public.rpg_setting('burn_cost')::integer; v_down integer; v_first boolean; v_r integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT v_s.on_map THEN RETURN; END IF;
  -- the first step of a turn may always be taken, whatever it costs, by the one whose turn it is before they have moved
  v_first := v_s.current_participant_id IS NOT DISTINCT FROM p_participant_id AND coalesce(v_s.turn_move_ticks, 0) = 0;
  IF v_b = 0 AND NOT v_first THEN RETURN; END IF;
  -- squares, not cost: the block round the fighter reaches as far as the budget goes on plain ground (100 a square)
  v_r := greatest(v_b / 100, 1);
  SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  x0 := greatest(v_p.pos_x - v_r, 1); w := least(v_p.pos_x + v_r, v_down * 2) - x0 + 1;
  y0 := greatest(v_p.pos_y - v_r, 1); h := least(v_p.pos_y + v_r, v_down) - y0 + 1;
  n := w * h;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_q IN SELECT * FROM public.rpg_fight_squares(v_s.id, x0, y0, w, h) LOOP
    i := (v_q.y - y0) * w + (v_q.x - x0) + 1;
    IF v_q.sea THEN blk[i] := true; ELSE pen[i] := v_q.penalty; END IF;
    fire[i] := CASE WHEN v_q.burning THEN v_burn ELSE 0 END;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND public.rpg_participant_blocks(o.id) LOOP
    IF v_o.pos_x BETWEEN x0 AND x0 + w - 1 AND v_o.pos_y BETWEEN y0 AND y0 + h - 1 THEN blk[(v_o.pos_y - y0) * w + (v_o.pos_x - x0) + 1] := true; END IF;
  END LOOP;
  d[(v_p.pos_y - y0) * w + (v_p.pos_x - x0) + 1] := 0;
  LOOP
    v_changed := false;
    FOR i IN 1..n LOOP
      CONTINUE WHEN d[i] >= v_big;
      cx := (i - 1) % w; cy := (i - 1) / w;
      FOR dx IN -1..1 LOOP
        FOR dy IN -1..1 LOOP
          nx := cx + dx; ny := cy + dy;
          CONTINUE WHEN (dx = 0 AND dy = 0) OR nx < 0 OR ny < 0 OR nx >= w OR ny >= h;
          j := ny * w + nx + 1;
          CONTINUE WHEN blk[j];
          c := d[i] + 100 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + fire[j];
          IF c < d[j] AND (c <= v_b OR (v_first AND d[i] = 0)) THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT x0 + (k - 1) % w, y0 + (k - 1) / w, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_budget(p_participant_id uuid, p_used integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The most path cost this fighter can still walk this turn, in hundredths of a plain square, when a turn holds
-- round_ticks (20) ticks of moving and p_used are spent: a plain square is move_ticks (5) at their Speed
-- (rpg_ticks_at), a square adding 60% is 8. Karen (Speed 1): 225, so 11.25 base ticks, 20 ticks for her; Zaboo
-- (Speed 5): 307; the Bramblemaw (Speed 7): 348. The first step of a turn may cost more (rpg_grid_costs).
DECLARE
  v_sp numeric := greatest(coalesce(public.rpg_participant_speed(p_participant_id), 0), 0);
  v_left integer := public.rpg_setting('round_ticks')::integer - coalesce(p_used, 0);
  v_mt numeric := public.rpg_setting('move_ticks');
  v_e numeric := public.rpg_setting('speed_even');
  v_c integer;
BEGIN
  IF v_left <= 0 THEN RETURN 0; END IF;
  -- the base time the ticks left can hold, as hundredths of a plain square, then nudged to the exact edge
  v_c := least(floor((v_left + 0.5) * (v_e + v_sp) / (2 * v_e) * 100 / v_mt)::integer, 100000);
  WHILE v_c > 0 AND public.rpg_ticks_at(v_sp, v_c * v_mt / 100) > v_left LOOP v_c := v_c - 1; END LOOP;
  WHILE v_c < 100000 AND public.rpg_ticks_at(v_sp, (v_c + 1) * v_mt / 100) <= v_left LOOP v_c := v_c + 1; END LOOP;
  RETURN v_c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_options(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares the one whose turn it is can still move to this turn, with the path cost (hundredths of a plain square)
-- and the ticks it takes: the path cost x move_ticks (5) / 100 at their Speed (rpg_ticks_at). A turn holds round_ticks
-- (20) ticks of moving (rpg_move_budget), and the first step of a turn may take longer (rpg_grid_costs): Zaboo
-- (Speed 5) reaches squares costing up to 307 (20 ticks), Karen (Speed 1) up to 225, and either can step into a
-- thicket next to them as a whole turn's move.
DECLARE v_p record; v_s record; v_sp numeric; v_mt numeric;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF v_s.status <> 'active' OR v_s.current_participant_id IS DISTINCT FROM v_p.id OR NOT public.rpg_participant_can_act(v_p.id) THEN
    RETURN '[]'::jsonb;
  END IF;
  v_sp := public.rpg_participant_speed(v_p.id);
  v_mt := public.rpg_setting('move_ticks');
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost, 'ticks', t.ticks) ORDER BY g.y, g.x), '[]'::jsonb)
            FROM public.rpg_grid_costs(v_p.id, public.rpg_move_budget(v_p.id, v_s.turn_move_ticks)) g
            CROSS JOIN LATERAL (SELECT public.rpg_ticks_at(v_sp, g.cost * v_mt / 100) AS ticks) t
           WHERE g.cost > 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_step_budget(p_beats integer)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
-- How far a step action goes, in path cost (hundredths of a plain square: each square 100 plus the percent of time it
-- adds): beats x ticks_per_beat x 100 / move_ticks, rounded down. Rootstep (1 beat): 10 x 100 / 5 = 200, two plain
-- squares.
SELECT floor(greatest(coalesce(p_beats, 1), 0) * public.rpg_setting('ticks_per_beat') * 100 / public.rpg_setting('move_ticks'))::integer;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_square(p_actor_id uuid, p_x integer, p_y integer, p_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A move on the board, which is the world map under the fight (squares counted from 1, as pieces stand; a fight off
-- the map has no board). With no action it is a walk by the one whose turn it is: the path cost (rpg_grid_costs) × 
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
  v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer; v_item record; v_forest boolean; v_pen integer;
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
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y WHERE id = p_actor_id;
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

CREATE OR REPLACE FUNCTION public.rpg_action_text(p_action_id uuid, p_skill numeric DEFAULT NULL::numeric)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One plain line for what a card's action does, built only from its row: the beats it takes as the creature's action
-- for a turn (actions only; a beat is 10 ticks at Speed 10, faster or slower by its Speed), its energy, its reach in
-- squares, the skill it rolls against which stat × the opponent multiplier, whether it does damage, and its effect.
-- With p_skill (a fight) the line carries the creature's number: "1 beat · 3 physical energy · Reach 1 square · Rolls
-- its Claw 10 against the target's Evade Enemy × 2 and does damage. A hit also rolls its Strength against the target's
-- Strength × 2; if that lands, the target is Knocked down and cannot act until their turn starts." A step (Rootstep)
-- says how far it goes (rpg_step_budget); a board action (Briar Shift) what it does to the ground. A revival rule (a
-- trait whose effect is on 'zero') gets its own line: "At 0 vitality it is Sunk and cannot act or be reached; after 2
-- rounds it rises with 1 vitality. A character ends it for good by rolling Healing (Spiritual) against its
-- Fascination with Evil × 2 (Sanctified)." So does a movement trait (Forest-Bound Terror). Other traits get no line.
-- An effect that exposes (Silenced, Judged) says who faces the target at × 1: every attacker, or the creature itself.
DECLARE
  a        public.rpg_creature_actions%ROWTYPE;
  v_names  jsonb;
  v_m      text := trim_scale(public.rpg_setting('opponent_will_multiplier'))::text;
  v_parts  text[] := '{}';
  v_fx     jsonb;
  v_ap     jsonb;
  v_fxt    text;
  v_line   text;
  v_n      integer;
BEGIN
  SELECT * INTO a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND OR (a.kind = 'trait' AND coalesce(a.effect->>'on', '') NOT IN ('zero', 'move')) THEN RETURN NULL; END IF;
  SELECT jsonb_object_agg(d.key, d.name) INTO v_names
    FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  IF a.effect->>'on' = 'zero' THEN
    RETURN 'At 0 vitality' || CASE WHEN a.effect ? 'where' THEN ' on ' || (a.effect->>'where') || ' ground (off the board counts)' ELSE '' END
        || ' it is ' || (a.effect->'apply'->>'name') || ' and cannot act or be reached; after '
        || (a.effect->'apply'->>'rounds') || ' rounds it rises with ' || coalesce(a.effect->'apply'->>'revive', '1') || ' vitality.'
        || CASE WHEN a.effect ? 'where' THEN ' Anywhere else it dies.' ELSE '' END
        || CASE WHEN a.effect ? 'fire' THEN ' Its square set alight while it waits burns it: it is ' || (a.effect->'fire'->>'name') || ' and will not rise.' ELSE '' END
        || CASE WHEN a.effect ? 'ended_by' THEN ' A character ends it for good by rolling '
             || coalesce(v_names->>(a.effect->'ended_by'->>'skill_key'), a.effect->'ended_by'->>'skill_key') || ' against its '
             || coalesce(v_names->>(a.effect->'ended_by'->>'against'), a.effect->'ended_by'->>'against') || ' × ' || v_m
             || ' (' || (a.effect->'ended_by'->>'name') || ').' ELSE '' END;
  END IF;
  IF a.effect->>'on' = 'move' THEN
    RETURN nullif(concat_ws(' ',
      CASE WHEN coalesce((a.effect->>'ignore_penalty')::boolean, false) THEN 'The ground never slows it: every square takes it the time of a plain one (fire still does).' END,
      CASE WHEN a.effect ? 'unseen' THEN 'On ' || (a.effect->'unseen'->>'where') || ' ground it is unseen beyond ' || (a.effect->'unseen'->>'beyond')
                                        || ' squares: no roll reaches it from farther away, whatever its reach.' END), '');
  END IF;

  IF a.kind = 'lair' THEN v_parts := v_parts || 'Once a round'::text; END IF;
  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN
    v_parts := v_parts || (a.beats || CASE WHEN a.beats = 1 THEN ' beat' ELSE ' beats' END);
  END IF;
  IF coalesce(a.energy_cost, 0) > 0 THEN
    v_parts := v_parts || (a.energy_cost || ' ' || a.energy_type || ' energy');
  END IF;
  IF a.skill_key IS NOT NULL OR a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Reach ' || a.reach || CASE WHEN a.reach = 1 THEN ' square' ELSE ' squares' END);
  END IF;
  IF a.skill_key IS NOT NULL THEN
    v_parts := v_parts || ('Rolls its ' || coalesce(v_names->>a.skill_key, a.skill_key)
                           || coalesce(' ' || trim_scale(p_skill)::text, '')
                           || ' against ' || CASE WHEN a.area THEN 'each target''s ' ELSE 'the target''s ' END
                           || coalesce(v_names->>a.against, a.against) || ' × ' || v_m
                           || CASE WHEN a.deals_damage THEN ' and does damage' ELSE '' END);
  END IF;
  IF a.effect->>'on' = 'step' THEN
    v_n := public.rpg_step_budget(coalesce((a.effect->>'beats')::integer, 1));
    v_parts := v_parts || ('Moves up to ' || trim_scale(round(v_n / 100.0, 2)) || CASE WHEN v_n = 100 THEN ' plain square' ELSE ' plain squares' END || ' of ground');
  END IF;
  IF a.effect->>'on' = 'board' AND coalesce((a.effect->>'burn')::boolean, false) THEN
    v_parts := v_parts || ('Sets a square in reach alight for ' || trim_scale(public.rpg_setting('burn_rounds'))::text || ' rounds: it takes +'
                           || trim_scale(public.rpg_setting('burn_cost'))::text || '% more time to step into, and a creature waiting there under a rule fire ends burns');
  ELSIF a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Every square within ' || coalesce(a.effect->>'radius', '0') || ' of a square in reach takes +'
                           || coalesce(a.effect->>'raise', '100') || '% more time to cross, up to +900%');
  END IF;
  v_line := array_to_string(v_parts, ' · ');

  v_fx := a.effect;
  IF v_fx IS NOT NULL AND v_fx ? 'apply' THEN
    v_ap := v_fx->'apply';
    IF v_fx->>'on' = 'self' THEN
      v_fxt := 'It is ' || (v_ap->>'name')
            || coalesce(' (' || (SELECT string_agg(coalesce(v_names->>b.k, b.k) || ' +' || b.v, ', ')
                                   FROM jsonb_each_text(v_ap->'bonus') AS b(k, v)) || ')', '')
            || CASE v_ap->>'clear' WHEN 'turn_start' THEN ' until its next turn starts'
                                   WHEN 'round' THEN ' until the next round' ELSE '' END;
    ELSE
      v_fxt := CASE
                 WHEN v_fx->>'on' = 'hit' AND v_fx ? 'contest' THEN
                   'A hit also rolls its ' || coalesce(v_names->>(v_fx->'contest'->>'skill_key'), v_fx->'contest'->>'skill_key')
                   || ' against the target''s ' || coalesce(v_names->>(v_fx->'contest'->>'against'), v_fx->'contest'->>'against')
                   || ' × ' || v_m || '; if that lands, the target is '
                 WHEN v_fx->>'on' = 'hit' THEN 'A hit also leaves the target '
                 WHEN a.area THEN 'Those it beats are '
                 ELSE 'If it beats the target, they are '
               END
            || (v_ap->>'name')
            || CASE WHEN coalesce((v_ap->>'cannot_act')::boolean, false) THEN ' and cannot act' ELSE '' END
            || CASE v_ap->>'clear'
                 WHEN 'turn_start' THEN ' until their turn starts'
                 WHEN 'round' THEN ' until the next round'
                 WHEN 'source_turn' THEN ' until its next turn starts'
                 WHEN 'check' THEN ': on each of their turns they roll '
                                   || coalesce(v_names->>(v_ap->>'check_stat'), v_ap->>'check_stat')
                                   || ' against ' || trim_scale((v_ap->>'check_difficulty')::numeric)::text || ' to shake it off'
                                   || CASE WHEN v_ap->>'on_fail' = 'no_attack' THEN ', and if that fails they cannot attack that turn' ELSE '' END
                 ELSE '' END
            || CASE v_ap->>'exposed'
                 WHEN 'all' THEN ', and every attacker faces their Evade Enemy × 1'
                 WHEN 'source' THEN ', and its own attacks face their Evade Enemy × 1'
                 ELSE '' END
            || CASE WHEN jsonb_typeof(v_ap->'on_harm') = 'object'
                    THEN '. If they attack an innocent (someone on the good side who has not attacked in this fight) or set forest ground alight while '
                         || (v_ap->>'name') || ', they are ' || (v_ap->'on_harm'->>'name') || ' for the rest of the fight'
                         || CASE v_ap->'on_harm'->>'exposed' WHEN 'source' THEN ': its own attacks face their Evade Enemy × 1' WHEN 'all' THEN ': every attacker faces their Evade Enemy × 1' ELSE '' END
                    ELSE '' END
            || CASE WHEN v_fx ? 'aim'
                    THEN '. An attack on the ' || (v_fx->>'aim') || ': the ' || coalesce((SELECT d.name FROM public.rpg_stat_definitions d WHERE d.guards = v_fx->>'aim' LIMIT 1), 'armor')
                         || ' absorbs up to its value of the attack''s strength first, and only what is left lands'
                    ELSE '' END;
    END IF;
    v_line := CASE WHEN v_line = '' THEN v_fxt ELSE v_line || '. ' || v_fxt END;
  END IF;
  RETURN nullif(v_line, '') || CASE WHEN nullif(v_line, '') IS NULL THEN '' ELSE '.' END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action. Only targets in the reach of the action count (rpg_in_reach: Claw 1 square, Briar Roar
-- 6). An area action (Briar Roar, Rending Swipe) goes at everyone in reach it scores anything on; any other goes at
-- the one target it scores highest on (Claw, Judging Gaze). An action on the creature itself (Sink Into Soil) needs
-- no target and is worth 10 unless it already has that effect. A step (Rootstep, up to rpg_step_budget: 200) is worth 8
-- when no character is next to it and it can get closer (rpg_step_target); a board action (Briar Shift) is worth 5 at
-- the square of the nearest character in its reach who is not next to it and whose ground is not already hard
-- (adding under 400% time). Returns the targets, the score, and for a step or board action the square; 0 with no targets
-- when nothing is worth doing.
DECLARE v_a record; v_t uuid; v_sc numeric; v_best uuid; v_top numeric := 0; v_list uuid[] := '{}'; v_sum numeric := 0; v_sq jsonb;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', 0); END IF;
  IF v_a.effect->>'on' = 'self' THEN
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score',
      CASE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e WHERE p.id = p_actor_id AND e->>'name' = v_a.effect->'apply'->>'name') THEN 0 ELSE 10 END);
  END IF;
  IF v_a.effect->>'on' = 'step' THEN
    v_sq := public.rpg_step_target(p_actor_id, public.rpg_step_budget(coalesce((v_a.effect->>'beats')::integer, 1)));
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 8 END, 'square', v_sq);
  END IF;
  IF v_a.effect->>'on' = 'board' THEN
    SELECT jsonb_build_object('x', p.pos_x, 'y', p.pos_y) INTO v_sq
      FROM unnest(coalesce(p_targets, '{}'::uuid[])) AS t(id)
      JOIN public.rpg_session_participants p ON p.id = t.id
      JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.pos_x IS NOT NULL AND public.rpg_distance(p_actor_id, p.id) BETWEEN 2 AND v_a.reach
       AND (SELECT f.penalty FROM public.rpg_fight_square(s.id, p.pos_x, p.pos_y) f) < 400
     ORDER BY public.rpg_distance(p_actor_id, p.id), p.pos_y, p.pos_x LIMIT 1;
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 5 END, 'square', v_sq);
  END IF;
  FOREACH v_t IN ARRAY coalesce(p_targets, '{}'::uuid[]) LOOP
    CONTINUE WHEN NOT public.rpg_in_reach(p_actor_id, v_t, v_a.reach);
    v_sc := public.rpg_action_score(p_actor_id, p_action_id, v_t);
    IF NOT v_a.area THEN
      IF v_sc > v_top THEN v_top := v_sc; v_best := v_t; END IF;
    ELSIF v_sc > 0 THEN
      v_list := v_list || v_t; v_sum := v_sum + v_sc;
    END IF;
  END LOOP;
  IF NOT v_a.area THEN
    RETURN jsonb_build_object('targets', CASE WHEN v_best IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_best) END, 'score', v_top);
  END IF;
  RETURN jsonb_build_object('targets', to_jsonb(v_list), 'score', v_sum);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_ignores_penalty(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether the ground never slows this one: a creature whose card has a move trait that says so (Forest-Bound Terror:
-- the Bramblemaw crosses briars at +260% in the time of a plain square). The one home of that test, read by
-- rpg_grid_costs on a fight board and rpg_map_walk on the world map.
SELECT EXISTS (SELECT 1 FROM public.rpg_session_participants p
                 JOIN public.rpg_creature_actions a ON a.creature_id = p.creature_id
                WHERE p.id = p_participant_id AND a.kind = 'trait' AND a.effect->>'on' = 'move'
                  AND coalesce((a.effect->>'ignore_penalty')::boolean, false));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_square_info(p_square jsonb, p_round integer)
 RETURNS TABLE(penalty integer, forest boolean, burning boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- One square of the board read the one way: the percent of time it adds (0 when unset), whether it is forest, and whether it
-- burns now (burn_until is the round the fire is out: lit in round 5 for 3 rounds it burns in 5, 6 and 7). Read by
-- rpg_grid_costs, rpg_participant_ground, rpg_best_aim, rpg_act_square and rpg_session_state; written by rpg_square_set.
SELECT coalesce((p_square->>'p')::integer, 0), coalesce((p_square->>'forest')::boolean, false),
       coalesce((p_square->>'burn_until')::integer, 0) > coalesce(p_round, 0);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everything the Play tab shows for one fight in one read: the fight, everyone in turn order with their effects and
-- whether they can act, a character's pending check (Frightened → Courage against 8, needs 54), the last 60 log
-- lines with their outcome keys. A creature's numbers come from the sheet it was made with; players get creatures
-- without numbers and no game-master lists. The game master gets each creature's stats (its own card's skills
-- first) and, on every action, the number it rolls (the Bramblemaw's Claw: 10) and one line of what it does
-- (rpg_action_text, the same line the creature card shows). Everyone sees whether a creature is out: 'out' is Dead,
-- or its revival rule's name (Sunk), and 'revival' says when it rises and which roll ends it for good.
-- The board (a fight on a journey; off the map there is none): the block of the world map round the one whose turn it
-- is, at least 13 squares a side and up to 24 to take in the fighters near them, the percent of time each square adds
-- (nothing for sea), forest and fire (rpg_fight_squares), its column and row names (rpg_square_name, within its own
-- battle grid), and for each fighter whether they stand on it and how far they are from its middle; burn_rounds and
-- burn_cost for the words; where everyone stands, each weapon's and action's
-- reach, and the squares the one whose turn it is can still reach this turn ('moves', with the path cost in hundredths of a plain square and the ticks).
-- The fight clock: the tick now, each fighter's Speed and next tick (ticks_away: how soon they act; the list runs in
-- that order), each weapon's and action's ticks for that fighter (Karen's sword 36), and what the turn so far costs
-- (turn_cost: moving 13 and acting 27 is 33).
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb; v_rev jsonb;
  v_board jsonb; v_cx integer; v_cy integer; v_bx0 integer; v_by0 integer; v_bw integer; v_bh integer; v_down integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY next_tick NULLS LAST, turn_order, created_at LOOP
    IF v_p.creature_id IS NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'ticks', public.rpg_action_ticks(v_p.id, d.beats, s->>'key'), 'energy_cost', d.energy_cost, 'energy_type', d.energy_type, 'reach', d.reach, 'bulk', s->'bulk')
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'item', i.name, 'line', public.rpg_action_text(a.id),
                                              'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END,
                                              'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false)) ORDER BY i.sort_order, a.sort_order), '[]'::jsonb)
                      FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
                      JOIN public.rpg_creature_actions a ON a.creature_id = o.template_id AND a.kind <> 'trait'
                     WHERE i.character_id = v_p.character_id AND i.equipped AND NOT i.worn AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean),
        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,
                            'difficulty', (e->>'check_difficulty')::numeric,
                            'skill', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                            'needed', public.rpg_needed((SELECT (s->>'value')::numeric FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                                                        (e->>'check_difficulty')::numeric)->'needed')
                            FROM jsonb_array_elements(v_p.effects) e JOIN public.rpg_stat_definitions d ON d.key = e->>'check_stat'
                           WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1));
    ELSE
      SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
      v_vit := public.rpg_participant_vitality(v_p.id);
      v_item := jsonb_build_object('kind', 'creature', 'creature_id', v_p.creature_id, 'color', v_c.color,
        'vitality_share', CASE WHEN (v_vit->>'max')::numeric > 0 THEN round((v_vit->>'left')::numeric / (v_vit->>'max')::numeric, 3) END);
      v_rev := NULL;
      SELECT e INTO v_rev FROM jsonb_array_elements(v_p.effects) e WHERE e ? 'ended_by' LIMIT 1;
      v_item := v_item || jsonb_build_object(
        'out', CASE WHEN (v_vit->>'left')::integer <= 0 THEN coalesce(v_rev->>'name', 'Dead') END,
        'revival', CASE WHEN v_rev IS NOT NULL THEN jsonb_build_object(
            'name', v_rev->>'name', 'rises_round', (v_rev->>'until_round')::integer, 'ends_as', v_rev->'ended_by'->>'name',
            'skill_key', v_rev->'ended_by'->>'skill_key',
            'skill_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = v_rev->'ended_by'->>'skill_key'),
            'against', v_rev->'ended_by'->>'against',
            'against_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = v_rev->'ended_by'->>'against')) END);
      IF v_gm THEN
        v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
        v_vals := (SELECT coalesce(jsonb_object_agg(s->>'key', s->'value'), '{}'::jsonb) FROM jsonb_array_elements(v_sheet->'stats') s);
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_vals->'AG',
          'skills', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'own', d.template_id = v_p.creature_id)
                                     ORDER BY (d.template_id IS DISTINCT FROM v_p.creature_id), o), '[]'::jsonb)
                       FROM jsonb_array_elements(v_sheet->'stats') WITH ORDINALITY AS t(s, o)
                       JOIN public.rpg_stat_definitions d ON d.key = s->>'key'),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill_key', a.skill_key,
                          'skill', v_vals->a.skill_key,
                          'line', public.rpg_action_text(a.id, (v_vals->>a.skill_key)::numeric),
                          'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END, 'ready', a.ready,
                          'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false))
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM (SELECT x.*, public.rpg_action_ready(v_p.id, x.id) AS ready FROM public.rpg_creature_actions x
                               WHERE x.creature_id = v_p.creature_id AND x.kind <> 'trait') a));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'energy', public.rpg_participant_energy(v_p.id), 'is_current', coalesce(v_p.id = v_s.current_participant_id, false),
                 'pos_x', v_p.pos_x, 'pos_y', v_p.pos_y, 'speed', public.rpg_participant_speed(v_p.id), 'next_tick', v_p.next_tick, 'ticks_away', v_p.next_tick - v_s.clock) || v_item);
  END LOOP;
  -- the board: centered on the one whose turn it is (or the first fighter on the map), grown to take in the fighters
  -- within 11 squares of that middle, at least 13 and at most 24 squares a side
  IF v_s.on_map THEN
    SELECT p.pos_x, p.pos_y INTO v_cx, v_cy FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
     ORDER BY (p.id = v_s.current_participant_id) DESC, (p.creature_id IS NOT NULL) DESC, p.turn_order, p.created_at LIMIT 1;
  END IF;
  IF v_cx IS NOT NULL THEN
    SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
    SELECT least(min(p.pos_x), v_cx - 6) - 2, least(min(p.pos_y), v_cy - 6) - 2, greatest(max(p.pos_x), v_cx + 6) + 2, greatest(max(p.pos_y), v_cy + 6) + 2
      INTO v_bx0, v_by0, v_bw, v_bh
      FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL AND public.rpg_square_gap(p.pos_x, p.pos_y, v_cx, v_cy) <= 11;
    v_bx0 := greatest(v_bx0, v_cx - 11, 1); v_by0 := greatest(v_by0, v_cy - 11, 1);
    v_bw := least(v_bw, v_cx + 12) - v_bx0 + 1; v_bh := least(v_bh, v_cy + 12, v_down) - v_by0 + 1;
    SELECT jsonb_build_object('x0', v_bx0, 'y0', v_by0, 'w', v_bw, 'h', v_bh,
             'cols', (SELECT jsonb_agg(left(public.rpg_square_name(gx, 1), 1) ORDER BY gx) FROM generate_series(v_bx0, v_bx0 + v_bw - 1) gx),
             'rows', (SELECT jsonb_agg(substr(public.rpg_square_name(1, gy), 2) ORDER BY gy) FROM generate_series(v_by0, v_by0 + v_bh - 1) gy),
             'squares', jsonb_agg(jsonb_build_array(f.penalty, f.forest, f.burning, f.sea) ORDER BY f.y, f.x))
      INTO v_board
      FROM public.rpg_fight_squares(p_session_id, v_bx0, v_by0, v_bw, v_bh) f;
    v_board := v_board || jsonb_build_object('away', (SELECT coalesce(jsonb_object_agg(p.id, public.rpg_square_gap(p.pos_x, p.pos_y, v_cx, v_cy)), '{}'::jsonb)
                                                         FROM public.rpg_session_participants p
                                                        WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
                                                          AND NOT (p.pos_x BETWEEN v_bx0 AND v_bx0 + v_bw - 1 AND p.pos_y BETWEEN v_by0 AND v_by0 + v_bh - 1)));
  END IF;

  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'on_map', v_s.on_map, 'board', v_board,
                 'burn_rounds', public.rpg_setting('burn_rounds'), 'burn_cost', public.rpg_setting('burn_cost'),
                 'clock', v_s.clock, 'round_ticks', public.rpg_setting('round_ticks'), 'turn_move_ticks', v_s.turn_move_ticks,
                 'turn_action_ticks', v_s.turn_action_ticks, 'turn_cost', public.rpg_turn_cost(v_s.turn_move_ticks, v_s.turn_action_ticks),
                 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'moves', CASE WHEN v_s.current_participant_id IS NULL THEN '[]'::jsonb ELSE public.rpg_move_options(v_s.current_participant_id) END,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND c.session_id IS NULL AND NOT public.rpg_is_object_card(c.template_id)
                          AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c
                       WHERE c.is_active AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.kind <> 'trait'))) END);
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
--   at the shore: nobody walks into the sea (2A); the piece stands on the last dry square before it;
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
  v_hour integer; v_d100 integer; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid; v_chance integer; v_cp uuid; v_gap integer;
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
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  SELECT l.steps INTO v_steps FROM public.rpg_map_line(v_sx, v_sy, v_gx, v_gy) l;
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even) * 100)::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax / 100.0) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / (v_mt * 100))::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 40 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, v_gx, v_gy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_r.k_from) s;
      v_pen := NULL;
      SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / l.cell)::integer, ((v_hy - 1) / l.cell)::integer, 1, 1) h))
        INTO v_pen
        FROM public.rpg_map_band(v_r.kind, v_r.place_id) b
        JOIN public.rpg_map_ladder() l ON l.level = v_r.level;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (100 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer);
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A)
      IF v_n > 0 THEN
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
      EXIT WHEN v_why = 'meet';
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back
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
     WHERE c.kind <> 'sea'
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
  v_walk := public.rpg_ticks_at(v_speed, v_base / 100.0);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR v_p.day_walk_ticks + v_walk >= v_day;
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea is in the way' ELSE 'someone is in the way' END;
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
  -- what the character saw on the way (rpg_map_found reads these stretches)
  IF v_k > 0 THEN PERFORM public.rpg_map_trail_add(v_p.character_id, v_sx + 1, v_sy + 1, v_tx + 1, v_ty + 1); END IF;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk) || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'shore' THEN ' The sea stops the walk.' ELSE '' END
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
-- (- for none). journey = the open journey, if any (a session played on the world map): its clock in words,
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
           'hard', CASE WHEN k.seen AND c.penalty IS NOT NULL AND c.hard IS NOT NULL THEN least(floor(c.hard * 10), 9)::integer END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || wx.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(wx.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows) c
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
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM public.rpg_map_costs(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) c
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id))
                                            ELSE g.ch END, '' ORDER BY d.x) AS line,
                       string_agg(CASE WHEN d.seen AND d.penalty IS NOT NULL AND d.hard IS NOT NULL THEN least(floor(d.hard * 10), 9)::integer::text
                                       ELSE '-' END, '' ORDER BY d.x) AS hard
                  FROM d CROSS JOIN u
                  LEFT JOIN public.rpg_map_grounds() g ON g.kind = d.kind
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'wrap', p_place IS NULL, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y),
                              'hard', CASE WHEN bool_or(ln.hard ~ '[0-9]') THEN jsonb_agg(ln.hard ORDER BY ln.y) END,
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

CREATE OR REPLACE FUNCTION public.rpg_creatures_place_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A place is a card under the Place card, and only a place has a spot on the world map. A place needs a center
-- (place_x, place_y, in world squares from the north-west corner) on the world, a size (place_w, place_h, in
-- squares) of 1 square up to the whole world, and a level (place_level): the kind of place it is, named by the grid
-- of the map ladder that is about it, 2 a continent, 3 a country, 4 a region, 5 a city, 6 a district, 7 a battle
-- grid.
-- Ground: a place with a percent of time added (place_penalty, 0 to 1,000, up to place_penalty_high, the same or
-- more; empty = the same) is ground of its own, forest or not (not, when not given): the Old Forest is forest at +20%
-- to +150%, each square somewhere in that range (rpg_map_band). A place with no percent only names the land, the way a continent or
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
       OR NEW.place_penalty IS NOT NULL OR NEW.place_penalty_high IS NOT NULL OR NEW.place_forest IS NOT NULL
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
    IF NEW.place_forest IS NOT NULL OR NEW.place_penalty_high IS NOT NULL THEN
      RAISE EXCEPTION '% adds no time to cross, so it only names the land: leave forest and the most percent empty too, or give it a percent (0 is open ground)', NEW.name;
    END IF;
  ELSE
    NEW.place_forest := coalesce(NEW.place_forest, false);
    NEW.place_penalty_high := coalesce(NEW.place_penalty_high, NEW.place_penalty);
    IF NEW.place_penalty NOT BETWEEN 0 AND 1000 OR NEW.place_penalty_high NOT BETWEEN NEW.place_penalty AND 1000 THEN
      RAISE EXCEPTION '%: the percent of time a square adds runs from 0 to 1000, and the most is at least the least', NEW.name;
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
END $function$;

CREATE OR REPLACE TRIGGER rpg_creatures_place_check BEFORE INSERT OR UPDATE OF parent_id, place_x, place_y, place_w, place_h, place_penalty, place_penalty_high, place_forest, place_level, place_icon ON public.rpg_creatures FOR EACH ROW EXECUTE FUNCTION rpg_creatures_place_check();

-- Place cards read as ranges (step 6 check, ISOM 2017 runnability and Soule & Goldman 1972):
-- Old Forest +100% -> forest +20% to +150% with thickets; Bramblemaw's Lair +200% -> +400% (all thicket);
-- Burnt Hills +200% -> hills +25% to +75%; The Fog +200% -> low wet ground, swamp +80% to +200%;
-- Thornfields +200% -> thorn scrub, difficult undergrowth +67% to +400%; open places +0% to +10%; the road +0%.
UPDATE public.rpg_creatures SET place_penalty = 20, place_penalty_high = 150 WHERE id = '7af286ae-d67a-4a2b-bede-4489fc23ea24';
UPDATE public.rpg_creatures SET place_penalty = 400, place_penalty_high = 400 WHERE id = '734aff41-21a2-4750-b256-5be5c8cd9ae3';
UPDATE public.rpg_creatures SET place_penalty = 25, place_penalty_high = 75 WHERE id = '9fddcae4-bbca-4de2-9c54-341793f3e62d';
UPDATE public.rpg_creatures SET place_penalty = 80, place_penalty_high = 200 WHERE id = '42cca630-2e09-400f-bec5-989f47a32b1a';
UPDATE public.rpg_creatures SET place_penalty = 67, place_penalty_high = 400 WHERE id = 'f92991a2-4884-486e-a8e7-1cfd773d6414';
UPDATE public.rpg_creatures SET place_penalty = 0, place_penalty_high = 10 WHERE id IN ('bf36bb24-19c2-4779-a96f-039bc87ccab9', 'a11fa880-d5d6-4986-aa3a-2a5ba01187be', 'fc99aef0-e5ee-41a1-ace9-6172b93d1ce0');
UPDATE public.rpg_creatures SET place_penalty = 0, place_penalty_high = 0 WHERE id = 'b079d1f0-3eac-43ca-b55c-4b71f443a67d';

-- Briar Shift: 2 more movement penalty (2 plain squares of time) is +200% time
UPDATE public.rpg_creature_actions SET effect = effect || '{"raise": 200}'::jsonb WHERE id = 'ff46f664-e22e-4273-a5be-3d8110d835a5' AND effect->>'raise' = '2';

-- Rule cards: moving and world_map read percents
UPDATE public.rpg_rules SET body = replace(replace(body,
'Every square has a movement penalty from 0 to 9, from the map: open land and grassy plains 0; hills and tundra 1; forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3. Nobody steps into the sea. Stepping into a square costs 1 plus its penalty, and a diagonal step costs the same as a straight one.
*Briars with penalty 2 cost 3 to step into: 15 ticks at Speed 10, 27 for Karen, more than a turn holds, so she goes around. The Bramblemaw ignores movement penalties.*',
'Every square adds its own share of time to cross it, set by the map. Each kind of ground has a range, taken from real walking studies: open land and grassy plains +0% to +10%; desert +10% to +110%; tundra +20% to +80%; hills +25% to +75%; forest and pine forest +20% to +150%, and one square in eight of them is a thicket of brambles at +400%; swamp +80% to +200%; jungle +100% to +300%; snow and ice +50% to +300%; mountains +200% to +500%. Where a square sits in its range never changes, so the thick parts of a forest stay thick, and the map draws harder squares darker. Nobody steps into the sea. A diagonal step costs the same as a straight one.
*A forest square at +60% takes 5 × 1.6 = 8 base ticks: 8 ticks at Speed 10, 8 × 20 ÷ 11 = 15 for Karen (Speed 1). Zaboo (Speed 5) crosses it and one plain square in 13 × 20 ÷ 15 = 17 ticks, with 3 left. The Bramblemaw ignores the ground: every square takes it the time of a plain one.*

A square that takes longer than a whole turn of moving can still be stepped into as the first move of a turn; that turn just takes longer.
*A thicket (+400%) is 5 × 5 = 25 base ticks: 25 × 20 ÷ 11 = 45 for Karen, so her turn takes 45 ticks instead of at most 20.*'),
'A burning square costs 3 more to step into, forest or not, for everyone.
*Briars of penalty 2 that are burning cost 1 + 2 + 3 = 6 to step into. The Bramblemaw ignores the briars but not the fire: 1 + 3 = 4.*',
'A burning square adds +300% more time to step into, forest or not, for everyone.
*Briar Shift adds +200% to the ground it hits, up to +900%: a forest square at +60% becomes +260%, 5 × 3.6 = 18 base ticks. Burning, it is +560%: 5 × 6.6 = 33 base ticks. The Bramblemaw ignores the briars but not the fire: +300%, 5 × 4 = 20 base ticks.*'),
       updated_at = now()
 WHERE id = 'ea8b2e3c-e7bb-408a-baf9-5a4e05acab3a';

UPDATE public.rpg_rules SET body = replace(replace(replace(body,
'Every square it steps into costs 1 plus its movement penalty, 5 ticks a point at Speed 10, faster or slower by Speed like everything else. Open land and grassy plains have penalty 0; hills and tundra 1; forest, pine forest, jungle and desert 2; mountains, swamp, snow and ice 3.',
'Every square it steps into takes 5 ticks at Speed 10 plus the share of time that square adds, faster or slower by Speed like everything else. The ranges are the same as on a fight board: open land +0% to +10%, forest +20% to +150% with thickets at +400%, mountains +200% to +500%, and so on. A walk longer than about 7 miles counts each 1.2-mile stretch as the average square of its ground.'),
'rough ground is hills, so a square of it costs 1 + 1 = 2.
*A mile is 1,439 squares. At Speed 10 a mile of open land is 1,439 x 5 = 7,195 ticks, 20 minutes: about 3 miles an hour. Zaboo (Speed 5) takes 7,195 x 20 / 15 = 9,593 ticks, 26 minutes 39 seconds. Mountains cost 4 a square, so a mile of them takes 1 hour 20 minutes at Speed 10.*',
'rough ground is hills, +25% to +75%.
*A mile is 1,439 squares. At Speed 10 a mile of open land, +5% on average, is 1,439 x 5 x 1.05 = 7,555 ticks, 21 minutes: about 2.9 miles an hour. Zaboo (Speed 5) takes 7,555 x 20 / 15 = 10,073 ticks, 28 minutes. Forest averages +124% with its thickets, so a mile of it takes 45 minutes at Speed 10; mountains average +350%, 1 hour 30 minutes.*'),
'*At Speed 10, 8 hours of open land is 24 miles.*',
'*At Speed 10, 8 hours of open land is about 23 miles.*'),
       updated_at = now()
 WHERE id = '43307999-7795-4893-beda-b2d1eb70ccac';

