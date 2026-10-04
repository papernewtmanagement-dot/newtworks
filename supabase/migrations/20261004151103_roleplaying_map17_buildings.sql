-- Step 8c (Peter 2026-10-03 23:12: "that climbing rule would go for any steep surfaces. So buildings too"; 2026-10-04
-- 14:10 "Go"): houses on the battle grid of every village, town and city, worked out from the map when asked and
-- never stored, the way the settlements and roads are. Houses line the roads that run through a settlement, in plots of
-- the widths medieval surveyors laid out in perches (5.03 m): both sides of its streets shared out among its households
-- (4.5 people a house), within a village toft of 2 to 4 perches (Roberts 1987), a town burgage of 1.5 to 2.5 (Conzen
-- 1960, Slater 1981), a city plot of 1 to 1.5; the plots are counted out from where each road
-- passes nearest the middle, and a settlement whose middle only one road reaches has that road run on through it as its
-- street. A village house is 4 to 5.5 m wide and 2 to 4 bays of 4.6 m long, one storey under thatch (45 to 55 degrees;
-- Dyer 1986, Gardiner 2014 on peasant houses); a town house fills its plot less a passage on half the plots and runs 2 to
-- 3 bays back, two storeys under clay tiles (40 to 50 degrees); a city house two or three storeys; a storey 2.4 to 2.9
-- m. A house stands only on its settlement's own dry ground, clear of every road and street and of the houses of the
-- plots counted before it, with no river or lake under its middle. Being laid off the roads and the middles, houses
-- move with them.
-- Climbing (Climbing rule card): the squares along a house's edge are its walls, sheer (90 degrees, difficulty 10),
-- climbing its height to the eaves; the squares inside are its roof, climbing like rock of its pitch. Walls and roofs take
-- their climb's time on a fight board and a Climbing roll on a move onto them, like a cliff; a walk goes round houses
-- along the streets and yards and never ends on one; a creature met in a haunt is never set down on one.
-- New: rpg_map_town_edge (a settlement's edge, now read by rpg_map_town_cells too, same cells), rpg_map_rects_meet,
-- rpg_map_climb_by (the climbing sums with the height given; rpg_map_climb is now one square of it, same results),
-- rpg_map_buildings (the one home of where houses stand; a block's houses kept for the transaction in rpg.houses),
-- rpg_map_building_cells. Changed in place: rpg_map_town_cells, rpg_map_climb, rpg_map_costs (a house's climb on its
-- squares), rpg_climb_check (walls and roofs), rpg_map_walk (never ends on a house), rpg_map_set_down (never on a
-- house), rpg_map_view_block (houses, and the climb of each square). 30 settings (map_house_*); the cards Climbing,
-- The World Map and Walking, and The Board and Moving. No drops, no table changes.

INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', n.key, n.value, n.label
  FROM (VALUES ('map_house_people', 4.5::numeric, 'Houses: people in a household, one to a house (medieval historians count 4.5 to 5)'),
               ('map_house_perch_m', 5.0292, 'Houses: metres in a perch (16 1/2 feet), the rod medieval plots were measured in'),
               ('map_house_bay_m', 4.6, 'Houses: metres in a bay, the length between two frames of a timber house (about 15 feet)'),
               ('map_house_plot_village_low', 2, 'Houses: narrowest village toft, perches wide (regular rows of tofts, Roberts 1987)'),
               ('map_house_plot_village_high', 4, 'Houses: widest village toft, perches wide'),
               ('map_house_plot_town_low', 1.5, 'Houses: narrowest town burgage, perches wide (burgages laid out in perches, about 2 the most common: Conzen 1960, Slater 1981)'),
               ('map_house_plot_town_high', 2.5, 'Houses: widest town burgage, perches wide'),
               ('map_house_plot_city_low', 1, 'Houses: narrowest city plot, perches wide (burgages split as a city filled up)'),
               ('map_house_plot_city_high', 1.5, 'Houses: widest city plot, perches wide'),
               ('map_house_span_low', 4, 'Houses: narrowest village house, metres (peasant houses 4 to 5.5 m wide: Dyer 1986, Gardiner 2014)'),
               ('map_house_span_high', 5.5, 'Houses: widest village house, metres'),
               ('map_house_bays_village_low', 2, 'Houses: fewest bays in a village house (a cottage)'),
               ('map_house_bays_village_high', 4, 'Houses: most bays in a village house (a longhouse)'),
               ('map_house_bays_town_low', 2, 'Houses: fewest bays a town or city house runs back from the street'),
               ('map_house_bays_town_high', 3, 'Houses: most bays a town or city house runs back from the street'),
               ('map_house_storeys_village_low', 1, 'Houses: fewest storeys in a village house'),
               ('map_house_storeys_village_high', 1, 'Houses: most storeys in a village house'),
               ('map_house_storeys_town_low', 2, 'Houses: fewest storeys in a town house'),
               ('map_house_storeys_town_high', 2, 'Houses: most storeys in a town house'),
               ('map_house_storeys_city_low', 2, 'Houses: fewest storeys in a city house'),
               ('map_house_storeys_city_high', 3, 'Houses: most storeys in a city house'),
               ('map_house_storey_low', 2.4, 'Houses: least metres from one floor to the next, or to the eaves'),
               ('map_house_storey_high', 2.9, 'Houses: most metres from one floor to the next, or to the eaves'),
               ('map_house_thatch_low', 45, 'Houses: least pitch of a thatched roof, degrees (thatch sheds rain only from 45 degrees up)'),
               ('map_house_thatch_high', 55, 'Houses: most pitch of a thatched roof, degrees (50 or more is usual)'),
               ('map_house_tile_low', 40, 'Houses: least pitch of a clay tile roof, degrees (plain tiles need about 40)'),
               ('map_house_tile_high', 50, 'Houses: most pitch of a clay tile roof, degrees'),
               ('map_house_setback_high', 4, 'Houses: most metres a village house stands back from its lane (town and city houses stand on the street)'),
               ('map_house_passage_m', 1, 'Houses: metres of passage beside a town or city house, on half the plots'),
               ('map_house_gap_m', 2, 'Houses: metres a village toft must leave beside its house for the house to stand long side to the lane, else it stands gable end on')) AS n(key, value, label);

CREATE OR REPLACE FUNCTION public.rpg_map_town_edge(p_a double precision, p_r double precision, p_shape double precision[])
 RETURNS double precision
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- How far the ground of a village, town or city reaches from its middle at the angle p_a (radians, east toward south):
-- its reach p_r times 1 plus its three waves (p_shape: the size and turn of waves of 2, 3 and 4 bumps a turn, from
-- rpg_map_town_make). The one home of where a settlement's edge runs: rpg_map_town_cells reads it for the cells inside,
-- rpg_map_buildings for the houses (step 8c).
SELECT p_r * (1 + p_shape[1] * cos(2 * p_a + p_shape[2]) + p_shape[3] * cos(3 * p_a + p_shape[4]) + p_shape[5] * cos(4 * p_a + p_shape[6]));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_rects_meet(p_ax double precision, p_ay double precision, p_aux double precision, p_auy double precision, p_ahl double precision, p_ahw double precision, p_bx double precision, p_by double precision, p_bux double precision, p_buy double precision, p_bhl double precision, p_bhw double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Whether two rectangles overlap by more than a hair (0.01 square): each given by its middle, the unit way along its
-- length, and its half length and half width. Two rectangles are apart when a line along one of their four sides keeps
-- them apart (the separating axis test); houses wall to wall in a row only touch, so they do not overlap (step 8c).
SELECT bool_and(abs((p_bx - p_ax) * n.x + (p_by - p_ay) * n.y)
                < p_ahl * abs(p_aux * n.x + p_auy * n.y) + p_ahw * abs(p_aux * n.y - p_auy * n.x)
                  + p_bhl * abs(p_bux * n.x + p_buy * n.y) + p_bhw * abs(p_bux * n.y - p_buy * n.x) - 0.01)
  FROM (VALUES (p_aux, p_auy), (-p_auy, p_aux), (p_bux, p_buy), (-p_buy, p_bux)) AS n(x, y);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climb_by(p_angle double precision, p_rise double precision)
 RETURNS TABLE(rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it takes to climb p_rise metres of a surface p_angle degrees steep: the one home of those sums (step 7c; step
-- 8c gave it the height, so a wall climbs its own height). Rock, the wall of a house and a roof all climb by it.
-- difficulty = default_difficulty (5) x the share of the body's weight the hands hold / map_climb_even_load (0.5):
--   that share is sin(angle) - map_foot_grip (0.8) x cos(angle), so 40 degrees is 0.3, 62 degrees 5, 85 degrees 9.3,
--   and a sheer wall (90 degrees) 10.
-- pct = the percent of time it adds to the square's 5 ticks: the rise at map_climb_rate (300 m an hour), ticks_per_hour
--   to the hour. 60 degrees of rock: 1.94 m, 139 ticks, +2,688%. A wall 2.6 m to the eaves: 187 ticks, +3,644%.
SELECT p_rise,
       round((public.rpg_setting('default_difficulty') * greatest(sin(radians(p_angle)) - public.rpg_setting('map_foot_grip')::double precision * cos(radians(p_angle)), 0)
              / public.rpg_setting('map_climb_even_load')::double precision)::numeric, 1),
       round((p_rise / public.rpg_setting('map_climb_rate')::double precision * public.rpg_setting('ticks_per_hour')::double precision
              / public.rpg_setting('move_ticks')::double precision - 1) * 100)::integer
 WHERE p_angle IS NOT NULL AND p_rise IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_town_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, kind text, name text, people integer, tx bigint, ty bigint, r double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block of the City grid or finer that lie inside a village, town or city (rpg_map_towns; step 8): the
-- middle of the cell is no farther from the middle of the settlement than its edge at that angle (rpg_map_town_edge: r
-- times 1 + its three waves, size x cos(bumps x angle + turn)), the edge the houses keep inside too (step 8c). The one home of what ground a settlement covers: rpg_map_cells makes those cells
-- town ground (unless they are water or belong to a place), the Maps tab names them by it. tx, ty = the middle of the
-- settlement, in world squares, counted the way the block counts. A coarser grid has none: there a settlement is a mark.
WITH lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     t AS MATERIALIZED (SELECT * FROM public.rpg_map_towns(p_level, p_x0, p_y0, p_cols, p_rows, NULL) t WHERE t.kind IS NOT NULL AND p_level >= 5)
SELECT DISTINCT ON (gx, gy) gx, gy, t.id, t.kind, t.name, t.people, t.x, t.y, t.r
  FROM t CROSS JOIN lad
 CROSS JOIN LATERAL (SELECT t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS far) f
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor((t.x - f.far) / lad.cell)::integer), least(p_x0 + p_cols - 1, floor((t.x + f.far) / lad.cell)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((t.y - f.far) / lad.cell)::integer), least(p_y0 + p_rows - 1, floor((t.y + f.far) / lad.cell)::integer)) AS gy
 CROSS JOIN LATERAL (SELECT (gx + 0.5) * lad.cell - t.x AS dx, (gy + 0.5) * lad.cell - t.y AS dy) d
 CROSS JOIN LATERAL (SELECT atan2(d.dy, d.dx) AS a) a
 WHERE sqrt(d.dx * d.dx + d.dy * d.dy) <= public.rpg_map_town_edge(a.a, t.r, t.shape)
 ORDER BY gx, gy, t.id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climb(p_angle double precision)
 RETURNS TABLE(rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it takes to climb one square of a surface p_angle degrees steep (rock, or the roof of a house): the climb of
-- rpg_map_climb_by, the one home of those sums, with the square's rise (step 7c; step 8c moved the sums there so a
-- wall can climb its own height).
-- rise = how many metres the square climbs (a square, map_square_m 1.118 m, x tan angle).
-- difficulty and pct as rpg_map_climb_by gives them: 40 degrees 0.3, 62 degrees 5, 85 degrees 9.3; 60 degrees climbs
--   1.94 m, 139 ticks, +2,688%.
SELECT c.rise, c.difficulty, c.pct
  FROM public.rpg_map_climb_by(p_angle, public.rpg_setting('map_square_m')::double precision * tan(radians(p_angle))) c;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_buildings(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision, half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The houses that stand on a block of the battle grid (step 8c, Peter 2026-10-03 23:12: buildings are climbed like
-- any steep surface), worked out when asked and never stored, the way the villages, towns and cities (rpg_map_towns)
-- and the roads (rpg_map_roads) are: the one home of where buildings stand. They are laid off the roads and the
-- settlements' middles, so a change to either moves them too. Only the battle grid has them; a coarser grid shows the
-- settlement's ground.
-- Every village, town and city (rpg_map_towns), and every village, town or city place card (Haven), lines each road,
-- lane or highway that runs through it with plots on both sides, the way medieval surveyors laid out a street. A
-- settlement has one plot width: both sides of all its streets shared out among its households (its people over
-- map_house_people, 4.5 a house), held inside its kind's range, map_house_plot_<kind>_low to _high perches
-- (map_house_perch_m, 5.03 m): a village toft 2 to 4 perches, a town burgage 1.5 to 2.5, a city plot 1 to 1.5
-- (Roberts 1987 on regular toft rows; Conzen 1960 and Slater 1981 on burgage widths in perches). A village of 120 on a
-- 270 m street gets 4-perch tofts and about 25 houses; a town of 3,500 on 3 km of streets 1.5-perch burgages. A card
-- (Haven) has as many people as its ground holds at its kind's crowding (map_<kind>_density). The plots are counted out
-- from where the road passes nearest the middle, so every block counts them alike. A settlement whose middle only one
-- road reaches lets that road run on through the middle as its street, to the far side, so a village at the end of its
-- lane still has a street through it.
-- Each plot rolls its own house (part 12, layers 1211 to 1219 for the left side, 1221 to 1229 for the right, at the
-- square in the middle of the plot on the road's line):
--   village: a cottage or longhouse 4 to 5.5 m wide (map_house_span_low, _high) and 2 to 4 bays long, a bay 4.6 m
--     (map_house_bay_m; the 15-foot bay of timber framing), one storey under thatch pitched 45 to 55 degrees
--     (map_house_thatch_low, _high), set back 0 to 4 m from the lane (map_house_setback_high); it stands long side to
--     the lane when its plot leaves map_house_gap_m (2 m) to spare, else gable end to the lane, and anywhere along its
--     plot (Dyer 1986 and Gardiner 2014 on peasant houses);
--   town: fills its plot's width less a passage (map_house_passage_m, 1 m) on half the plots, 2 to 3 bays deep,
--     two storeys, on the street line, under clay tiles pitched 40 to 50 degrees (map_house_tile_low, _high);
--   city: the same with two or three storeys.
-- Storeys and their height come from map_house_storeys_<kind>_low, _high and map_house_storey_low, _high (2.4 to 2.9 m
-- a storey, to the eaves). The ridge runs along the longer side.
-- A house stands only when the whole of it lies on its settlement's own ground (its corners and the middles of its
-- sides: rpg_map_town_edge, or the card's own edge, rpg_map_within), clear of every road and street (half its width
-- from its line), clear of the houses of a bigger road, of the road counted first and of the plots nearer the middle,
-- on dry land (no sea under it, rpg_map_heights) and with no river or lake under its middle (rpg_map_flow).
-- Returns the houses that reach into the block: id (h<road>-<x>-<y><side>), the settlement, its kind, roof (thatch or
-- tile), its middle (cx, cy, world squares counted the way the block counts), the way its ridge runs (ux, uy), half its
-- length and width in squares, the height to its eaves in metres, its roof's pitch in degrees and its storeys.
-- One read of the map asks for the same ground more than once (a block's costs, then its picture; a fight board, then
-- the climb onto one square), so what is worked out is kept in settings of the transaction and gone when it ends: each
-- settlement's streets and plot width (rpg.townstreets, by settlement), whether each house stands on its own dry
-- ground (rpg.houseok, by house) and each block's houses (rpg.houses, by block "x,y,cols,rows").
#variable_conflict use_column
DECLARE
  v_key text := p_x0 || ',' || p_y0 || ',' || p_cols || ',' || p_rows;
  v_all jsonb;
  v_c jsonb;
  g record;
  t record;
  v_tw jsonb;
  v_tl jsonb;
  v_hb jsonb;
  v_ok jsonb;
  v_new jsonb;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.houses', true), ''), '{}')::jsonb;
  v_c := v_all -> v_key;
  IF v_c IS NULL THEN
    -- the numbers, read once; r = how far a house reaches from its middle at most, in squares (half the diagonal of
    -- the biggest house, and one more)
    WITH st AS (SELECT s.key, s.value::double precision AS v FROM public.rpg_settings s
                 WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                   AND (s.key LIKE 'map\_house\_%' OR s.key IN ('map_square_m', 'map_seed', 'map_edge_share', 'map_sea_level',
                                                                'map_road_1_width', 'map_road_2_width', 'map_road_3_width'))),
         cfg AS (
           SELECT max(st.v) FILTER (WHERE st.key = 'map_square_m') AS sq, max(st.v) FILTER (WHERE st.key = 'map_seed')::integer AS seed,
                  max(st.v) FILTER (WHERE st.key = 'map_edge_share') AS share, max(st.v) FILTER (WHERE st.key = 'map_sea_level') AS sea,
                  max(st.v) FILTER (WHERE st.key = 'map_house_perch_m') AS perch, max(st.v) FILTER (WHERE st.key = 'map_house_bay_m') AS bay,
                  max(st.v) FILTER (WHERE st.key = 'map_house_span_low') AS span_lo, max(st.v) FILTER (WHERE st.key = 'map_house_span_high') AS span_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_storey_low') AS storey_lo, max(st.v) FILTER (WHERE st.key = 'map_house_storey_high') AS storey_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_thatch_low') AS thatch_lo, max(st.v) FILTER (WHERE st.key = 'map_house_thatch_high') AS thatch_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_tile_low') AS tile_lo, max(st.v) FILTER (WHERE st.key = 'map_house_tile_high') AS tile_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_setback_high') AS setback_hi, max(st.v) FILTER (WHERE st.key = 'map_house_passage_m') AS passage,
                  max(st.v) FILTER (WHERE st.key = 'map_house_gap_m') AS gap, max(st.v) FILTER (WHERE st.key = 'map_house_people') AS household,
                  max(st.v) FILTER (WHERE st.key = 'map_house_bays_village_low') AS vbays_lo, max(st.v) FILTER (WHERE st.key = 'map_house_bays_village_high') AS vbays_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_house_bays_town_low') AS tbays_lo, max(st.v) FILTER (WHERE st.key = 'map_house_bays_town_high') AS tbays_hi,
                  max(st.v) FILTER (WHERE st.key IN ('map_house_plot_town_high', 'map_house_plot_city_high')) AS plot_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_road_1_width') AS w1, max(st.v) FILTER (WHERE st.key = 'map_road_2_width') AS w2,
                  max(st.v) FILTER (WHERE st.key = 'map_road_3_width') AS w3,
                  (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1)::double precision AS world
             FROM st)
    SELECT cfg.*, ceil(greatest(sqrt(power(cfg.vbays_hi * cfg.bay, 2) + power(cfg.span_hi, 2)),
                                sqrt(power(cfg.tbays_hi * cfg.bay, 2) + power(cfg.plot_hi * cfg.perch, 2))) / 2 / cfg.sq) + 1 AS r
      INTO g FROM cfg;

    -- the villages, towns and cities whose ground reaches the box of the houses that might overlap those reaching the
    -- block (three reaches round it): the rolled ones, and the place cards of a village, town or city (their oval grown
    -- by how far their edge may wander; the copy nearest the block)
    SELECT coalesce(jsonb_agg(q), '[]') INTO v_tw
      FROM (SELECT t.id AS town, t.kind, t.x::double precision AS mx, t.y::double precision AS my, t.r, t.shape, NULL::uuid AS card, t.people,
                   NULL::double precision AS cw, NULL::double precision AS ch,
                   t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fx, t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fy
              FROM public.rpg_map_towns(7, (p_x0 - 3 * g.r)::integer, (p_y0 - 3 * g.r)::integer, (p_cols + 6 * g.r)::integer, (p_rows + 6 * g.r)::integer, NULL) t
             WHERE t.kind IS NOT NULL
            UNION ALL
            SELECT c.id::text, c.place_icon, c.place_x + g.world * floor((p_x0 + p_cols / 2.0 - c.place_x) / g.world + 0.5), c.place_y, NULL, NULL, c.id, NULL,
                   c.place_w / 2.0, c.place_h / 2.0,
                   public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share) / 2.0, public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share) / 2.0
              FROM public.rpg_creatures c
             WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
               AND c.place_penalty IS NOT NULL AND c.place_icon IN ('village', 'town', 'city')
               AND public.rpg_map_touches(p_x0 - 3 * g.r, p_y0 - 3 * g.r, p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r, c.place_x, c.place_y,
                                          public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share),
                                          public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share), g.world::integer)) q;

    IF jsonb_array_length(v_tw) = 0 THEN
      v_c := '[]'::jsonb;
    ELSE
      -- each settlement's streets and plot width, once a transaction
      v_tl := coalesce(nullif(current_setting('rpg.townstreets', true), ''), '{}')::jsonb;
      FOR t IN SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision, shape double precision[],
                                                           card uuid, people integer, cw double precision, ch double precision, fx double precision, fy double precision) LOOP
        CONTINUE WHEN v_tl ? t.town;
        -- every road that crosses it (rpg_map_roads over the whole settlement), in a steady order; each one's line: the
        -- way along it (u) and across it (n), where it passes the middle (t0, along it from a), the half width of its
        -- street, and how far along it houses may stand (lo to hi): the road itself, and for the one road at a middle no
        -- other road reaches, on through the middle to the far side
        WITH rl AS MATERIALIZED (
               SELECT r.class, r.ax, r.ay, r.bx, r.by, row_number() OVER (ORDER BY r.class, r.a, r.b, r.ax, r.ay) AS k
                 FROM public.rpg_map_roads(7, floor(t.mx - t.fx)::integer, floor(t.my - t.fy)::integer,
                                           (ceil(2 * t.fx) + 2)::integer, (ceil(2 * t.fy) + 2)::integer, 7, NULL, 0) r),
             ln AS MATERIALIZED (
               SELECT rl.k, rl.class, rl.ax, rl.ay, d.len, d.ux, d.uy, -d.uy AS nx, d.ux AS ny,
                      (t.mx - rl.ax) * d.ux + (t.my - rl.ay) * d.uy AS t0,
                      CASE rl.class WHEN 1 THEN g.w1 WHEN 2 THEN g.w2 ELSE g.w3 END / 2 AS half,
                      sqrt(power(rl.ax - t.mx, 2) + power(rl.ay - t.my, 2)) < 1 AS at_a,
                      sqrt(power(rl.bx - t.mx, 2) + power(rl.by - t.my, 2)) < 1 AS at_b
                 FROM rl
                CROSS JOIN LATERAL (SELECT sqrt(power(rl.bx - rl.ax, 2) + power(rl.by - rl.ay, 2)) AS len) l0
                CROSS JOIN LATERAL (SELECT l0.len, (rl.bx - rl.ax) / l0.len AS ux, (rl.by - rl.ay) / l0.len AS uy) d
                WHERE l0.len > 0),
             lr AS MATERIALIZED (
               SELECT ln.*,
                      CASE WHEN ln.at_a AND m.n = 1 THEN -greatest(t.fx, t.fy) ELSE 0 END AS lo,
                      CASE WHEN ln.at_b AND m.n = 1 THEN ln.len + greatest(t.fx, t.fy) ELSE ln.len END AS hi
                 FROM ln CROSS JOIN (SELECT count(*) FILTER (WHERE q.at_a OR q.at_b) AS n FROM ln q) m),
             -- how much street runs through it: every line, measured a square at a time where it lies on the
             -- settlement's ground (a card's plain oval for this sum)
             sl AS (
               SELECT count(*) AS len
                 FROM lr
                CROSS JOIN LATERAL (SELECT abs((t.mx - lr.ax) * lr.nx + (t.my - lr.ay) * lr.ny) AS d, greatest(t.fx, t.fy) AS far) q
                CROSS JOIN LATERAL (SELECT greatest(lr.lo, lr.t0 - sqrt(greatest(q.far * q.far - q.d * q.d, 0))) AS ts,
                                           least(lr.hi, lr.t0 + sqrt(greatest(q.far * q.far - q.d * q.d, 0))) AS te) e
                CROSS JOIN LATERAL generate_series(0, greatest(floor(e.te - e.ts)::integer - 1, -1)) AS i
                CROSS JOIN LATERAL (SELECT lr.ax + lr.ux * (e.ts + i + 0.5) AS x, lr.ay + lr.uy * (e.ts + i + 0.5) AS y) p
                WHERE CASE WHEN t.card IS NULL
                           THEN sqrt(power(p.x - t.mx, 2) + power(p.y - t.my, 2)) <= public.rpg_map_town_edge(atan2(p.y - t.my, p.x - t.mx), t.r, t.shape)
                           ELSE power((p.x - t.mx) / t.cw, 2) + power((p.y - t.my) / t.ch, 2) <= 1 END),
             -- the plot width, in squares: both sides of the streets shared out among the households (people: a rolled
             -- settlement's own count; a card's ground at its kind's crowding, map_<kind>_density), inside its kind's range
             pw AS (
               SELECT least(greatest(2 * sl.len * g.sq / nullif(h.people / g.household, 0),
                                     (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_plot_' || t.kind || '_low') * g.perch),
                            (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_plot_' || t.kind || '_high') * g.perch) / g.sq AS f
                 FROM sl
                CROSS JOIN LATERAL (SELECT coalesce(t.people::double precision,
                                                    pi() * t.cw * t.ch * g.sq * g.sq / 10000
                                                    * (SELECT s.value FROM public.rpg_settings s
                                                        WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_' || t.kind || '_density')) AS people) h)
        SELECT jsonb_build_object('f', (SELECT pw.f FROM pw),
                                  'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('k', lr.k, 'class', lr.class, 'ax', lr.ax, 'ay', lr.ay, 'len', lr.len,
                                                                                         'ux', lr.ux, 'uy', lr.uy, 'nx', lr.nx, 'ny', lr.ny, 't0', lr.t0,
                                                                                         'half', lr.half, 'lo', lr.lo, 'hi', lr.hi) ORDER BY lr.k)
                                                       FROM lr), '[]'::jsonb))
          INTO v_new;
        v_tl := v_tl || jsonb_build_object(t.town, v_new);
      END LOOP;
      PERFORM set_config('rpg.townstreets', v_tl::text, true);

      -- the plots near the block and the house each holds
      WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                             shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                             fx double precision, fy double precision)),
           lr AS MATERIALIZED (
             SELECT tw.town, tw.kind, (v_tl -> tw.town ->> 'f')::double precision AS f, l.*
               FROM tw CROSS JOIN LATERAL jsonb_to_recordset(v_tl -> tw.town -> 'lines')
                       AS l(k integer, class integer, ax double precision, ay double precision, len double precision, ux double precision, uy double precision,
                            nx double precision, ny double precision, t0 double precision, half double precision, lo double precision, hi double precision)),
           -- the plots of each line near the box (three reaches round the block): its corners measured along and across
           pr AS MATERIALIZED (
             SELECT lr.*, q.tmin, q.tmax
               FROM lr
              CROSS JOIN LATERAL (SELECT min((c.x - lr.ax) * lr.ux + (c.y - lr.ay) * lr.uy) AS tmin, max((c.x - lr.ax) * lr.ux + (c.y - lr.ay) * lr.uy) AS tmax,
                                         min((c.x - lr.ax) * lr.nx + (c.y - lr.ay) * lr.ny) AS smin, max((c.x - lr.ax) * lr.nx + (c.y - lr.ay) * lr.ny) AS smax
                                    FROM (VALUES (p_x0 - 3 * g.r, p_y0 - 3 * g.r), (p_x0 + p_cols + 3 * g.r, p_y0 - 3 * g.r),
                                                 (p_x0 - 3 * g.r, p_y0 + p_rows + 3 * g.r), (p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r)) AS c(x, y)) q
              -- a house stands at most a street, a setback and a house's length from its line
              WHERE lr.f > 0
                AND q.smin <= lr.half + (g.setback_hi + g.vbays_hi * g.bay) / g.sq + g.r
                AND q.smax >= -(lr.half + (g.setback_hi + g.vbays_hi * g.bay) / g.sq + g.r)),
           pl AS MATERIALIZED (
             SELECT pr.town, pr.kind, pr.k, pr.class, pr.ax, pr.ay, pr.ux, pr.uy, pr.nx, pr.ny, pr.half, pr.f, j,
                    pr.t0 + (j + 0.5) * pr.f AS tm, s.side, pr.t0 + (j + 0.5) * pr.f < 0 OR pr.t0 + (j + 0.5) * pr.f > pr.len AS cont
               FROM pr
              CROSS JOIN LATERAL generate_series(greatest(ceil((pr.lo - pr.t0) / pr.f - 1e-6), floor((pr.tmin - pr.t0) / pr.f) - 1)::integer,
                                                 least(floor((pr.hi - pr.t0) / pr.f + 1e-6) - 1, ceil((pr.tmax - pr.t0) / pr.f) + 1)::integer) AS j
              CROSS JOIN (VALUES (-1), (1)) AS s(side)),
           -- each plot's own rolls (u1 to u9, 0 to 1) at the square in its middle on the road's line
           pu AS MATERIALIZED (
             SELECT pl.*, round(pl.ax + pl.ux * pl.tm)::integer AS px, round(pl.ay + pl.uy * pl.tm)::integer AS py,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + CASE WHEN pl.side > 0 THEN 10 ELSE 0 END + n,
                                                           round(pl.ax + pl.ux * pl.tm)::integer, round(pl.ay + pl.uy * pl.tm)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u
               FROM pl),
           -- the house of each plot, in metres
           hm AS (
             SELECT pu.*, d.*
               FROM pu
              CROSS JOIN LATERAL (
                SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_storeys_' || pu.kind || '_low') AS s_lo,
                       (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_storeys_' || pu.kind || '_high') AS s_hi) k
              CROSS JOIN LATERAL (
                SELECT (k.s_lo + least(floor((k.s_hi - k.s_lo + 1) * pu.u[3]), k.s_hi - k.s_lo))::integer AS storeys,
                       g.span_lo + (g.span_hi - g.span_lo) * pu.u[1] AS span,
                       CASE WHEN pu.kind = 'village' THEN g.vbays_lo + least(floor((g.vbays_hi - g.vbays_lo + 1) * pu.u[2]), g.vbays_hi - g.vbays_lo)
                            ELSE g.tbays_lo + least(floor((g.tbays_hi - g.tbays_lo + 1) * pu.u[2]), g.tbays_hi - g.tbays_lo) END * g.bay AS length,
                       g.storey_lo + (g.storey_hi - g.storey_lo) * pu.u[4] AS storey,
                       CASE WHEN pu.kind = 'village' THEN g.thatch_lo + (g.thatch_hi - g.thatch_lo) * pu.u[5]
                            ELSE g.tile_lo + (g.tile_hi - g.tile_lo) * pu.u[5] END AS pitch,
                       CASE WHEN pu.kind = 'village' THEN g.setback_hi * pu.u[6] ELSE 0 END AS setback,
                       CASE WHEN pu.kind <> 'village' AND pu.u[7] < 0.5 THEN g.passage ELSE 0 END AS passage) d),
           -- along = along the road, deep = back from it; a village house long side to the lane when its toft leaves
           -- map_house_gap_m beside it, else gable end on; a town or city house fills its plot less any passage
           hs AS (
             SELECT hm.*, a.along, a.deep,
                    CASE WHEN hm.kind = 'village' THEN (hm.f * g.sq - a.along) * (hm.u[7] - 0.5)
                         WHEN hm.u[8] < 0.5 THEN -hm.passage / 2 ELSE hm.passage / 2 END AS off
               FROM hm
              CROSS JOIN LATERAL (
                SELECT CASE WHEN hm.kind <> 'village' THEN hm.f * g.sq - hm.passage
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.length ELSE hm.span END AS along,
                       CASE WHEN hm.kind <> 'village' THEN hm.length
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.span ELSE hm.length END AS deep) a),
           -- in squares on the map: the middle, the way of the ridge and the half sides
           hc AS MATERIALIZED (
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side,
                    'h' || hs.k || '-' || hs.px || '-' || hs.py || CASE WHEN hs.side > 0 THEN 'r' ELSE 'l' END AS id,
                    hs.ax + hs.ux * (hs.tm + hs.off / g.sq) + hs.nx * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cx,
                    hs.ay + hs.uy * (hs.tm + hs.off / g.sq) + hs.ny * hs.side * (hs.half + (hs.setback + hs.deep / 2) / g.sq) AS cy,
                    CASE WHEN hs.along >= hs.deep THEN hs.ux ELSE hs.nx END AS rx, CASE WHEN hs.along >= hs.deep THEN hs.uy ELSE hs.ny END AS ry,
                    greatest(hs.along, hs.deep) / 2 / g.sq AS hl, least(hs.along, hs.deep) / 2 / g.sq AS hw,
                    hs.storeys * hs.storey AS eaves, hs.pitch, hs.storeys,
                    CASE WHEN hs.kind = 'village' THEN 'thatch' ELSE 'tile' END AS roof
               FROM hs),
           -- the houses in that box that keep clear of every road and street of their settlement, each with its place
           -- in the order: bigger road first, then the road counted first, its own road before the street it runs on as,
           -- then the plot nearer the middle
           cl AS MATERIALIZED (
             SELECT hc.*, row_number() OVER (PARTITION BY hc.town ORDER BY hc.class, hc.k, hc.cont, abs(hc.j), hc.j, hc.side) AS n
               FROM hc
              WHERE hc.cx BETWEEN p_x0 - 3 * g.r AND p_x0 + p_cols + 3 * g.r AND hc.cy BETWEEN p_y0 - 3 * g.r AND p_y0 + p_rows + 3 * g.r
                AND NOT EXISTS (
                      SELECT 1 FROM lr
                       CROSS JOIN LATERAL (SELECT lr.ax + lr.ux * lr.lo - hc.cx AS x0, lr.ay + lr.uy * lr.lo - hc.cy AS y0,
                                                  lr.ax + lr.ux * lr.hi - hc.cx AS x1, lr.ay + lr.uy * lr.hi - hc.cy AS y1) e
                       WHERE lr.town = hc.town
                         AND public.rpg_seg_box(e.x0 * hc.rx + e.y0 * hc.ry, e.y0 * hc.rx - e.x0 * hc.ry, e.x1 * hc.rx + e.y1 * hc.ry, e.y1 * hc.rx - e.x1 * hc.ry,
                                                -(hc.hl + lr.half - 0.01), -(hc.hw + lr.half - 0.01), hc.hl + lr.half - 0.01, hc.hw + lr.half - 0.01)))
      -- of those, the ones that reach the block and are clear of the houses before them
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', cl.id, 'town', cl.town, 'kind', cl.kind, 'roof', cl.roof, 'cx', cl.cx, 'cy', cl.cy,
                                                   'ux', cl.rx, 'uy', cl.ry, 'half_len', cl.hl, 'half_wide', cl.hw, 'eaves', cl.eaves,
                                                   'pitch', cl.pitch, 'storeys', cl.storeys) ORDER BY cl.town, cl.n), '[]'::jsonb)
        INTO v_hb
        FROM cl
       WHERE public.rpg_map_rects_meet(cl.cx, cl.cy, cl.rx, cl.ry, cl.hl, cl.hw, p_x0 + p_cols / 2.0, p_y0 + p_rows / 2.0, 1, 0, p_cols / 2.0, p_rows / 2.0)
         AND NOT EXISTS (SELECT 1 FROM cl c2
                          WHERE c2.town = cl.town AND c2.n < cl.n
                            AND public.rpg_map_rects_meet(cl.cx, cl.cy, cl.rx, cl.ry, cl.hl, cl.hw, c2.cx, c2.cy, c2.rx, c2.ry, c2.hl, c2.hw));

      -- whether each stands on its own dry ground, once a transaction: the four corners and the middles of the four
      -- sides, a hair in, on its settlement's ground and not the sea; no river or lake under its middle
      v_ok := coalesce(nullif(current_setting('rpg.houseok', true), ''), '{}')::jsonb;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_hb) h WHERE NOT v_ok ? (h ->> 'id')) THEN
        WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                               shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                               fx double precision, fy double precision)),
             hb AS (SELECT * FROM jsonb_to_recordset(v_hb) AS h(id text, town text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                                half_len double precision, half_wide double precision)
                     WHERE NOT v_ok ? h.id),
             pt AS MATERIALIZED (
               SELECT hb.id, hb.town, q.a * (hb.half_len - 0.01) * hb.ux - q.b * (hb.half_wide - 0.01) * hb.uy + hb.cx AS x,
                      q.a * (hb.half_len - 0.01) * hb.uy + q.b * (hb.half_wide - 0.01) * hb.ux + hb.cy AS y
                 FROM hb CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             -- the land and sea under them, and a card's own edge, read once as a block
             ab AS (SELECT floor(min(pt.x))::integer AS x0, floor(min(pt.y))::integer AS y0,
                           (floor(max(pt.x)) - floor(min(pt.x)) + 1)::integer AS cols, (floor(max(pt.y)) - floor(min(pt.y)) + 1)::integer AS rows
                      FROM pt),
             ht AS MATERIALIZED (SELECT h.x, h.y, h.height FROM ab CROSS JOIN LATERAL public.rpg_map_heights(7, ab.x0, ab.y0, ab.cols, ab.rows) h),
             wn AS MATERIALIZED (
               SELECT tw.town, w.x, w.y FROM tw CROSS JOIN ab CROSS JOIN LATERAL public.rpg_map_within(tw.card, 7, ab.x0, ab.y0, ab.cols, ab.rows) w
                WHERE tw.card IS NOT NULL AND EXISTS (SELECT 1 FROM hb WHERE hb.town = tw.town))
        SELECT v_ok || coalesce(jsonb_object_agg(hb.id,
                 NOT EXISTS (SELECT 1 FROM pt
                               LEFT JOIN ht ON ht.x = floor(pt.x) AND ht.y = floor(pt.y)
                              WHERE pt.id = hb.id
                                AND (coalesce(ht.height, -1e9) < g.sea
                                     OR CASE WHEN tw.card IS NULL
                                             THEN sqrt(power(pt.x - tw.mx, 2) + power(pt.y - tw.my, 2)) > public.rpg_map_town_edge(atan2(pt.y - tw.my, pt.x - tw.mx), tw.r, tw.shape)
                                             ELSE NOT EXISTS (SELECT 1 FROM wn WHERE wn.town = tw.town AND wn.x = floor(pt.x) AND wn.y = floor(pt.y)) END))
                 AND NOT EXISTS (SELECT 1 FROM public.rpg_map_flow(7, floor(hb.cx)::integer, floor(hb.cy)::integer, 1, 1) f WHERE f.depth > 0)), '{}'::jsonb)
          INTO v_ok
          FROM hb JOIN tw ON tw.town = hb.town;
        PERFORM set_config('rpg.houseok', v_ok::text, true);
      END IF;
      SELECT coalesce(jsonb_agg(h ORDER BY n), '[]'::jsonb) INTO v_c
        FROM jsonb_array_elements(v_hb) WITH ORDINALITY AS e(h, n)
       WHERE (v_ok ->> (h ->> 'id'))::boolean;
    END IF;
    PERFORM set_config('rpg.houses', jsonb_set(v_all, ARRAY[v_key], v_c)::text, true);
  END IF;
  RETURN QUERY
  SELECT h.id, h.town, h.kind, h.roof, h.cx, h.cy, h.ux, h.uy, h.half_len, h.half_wide, h.eaves, h.pitch, h.storeys
    FROM jsonb_to_recordset(v_c) AS h(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                      half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_building_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that a house stands on (step 8c; rpg_map_buildings, the one home of where
-- houses stand): every square whose middle lies inside one. The squares along its edge (within one square of it) are
-- its walls, the rest its roof. Each is a steep surface, climbed by the Climbing rule (rpg_map_climb_by, Peter
-- 2026-10-03 23:12: the climbing rule goes for any steep surface, buildings too): a wall is sheer (90 degrees,
-- difficulty 10) and climbs the house's height to the eaves; a roof square climbs like rock of the roof's pitch, one
-- square's worth (rpg_map_climb: thatch at 50 degrees 1.33 m, difficulty 2.5). angle = how steep, rise = metres
-- climbed, difficulty of the Climbing roll, pct = the percent of time it adds to the square. Ground underneath is
-- whatever rpg_map_cells says (the settlement's streets and yards); the house stands on it, the way a cliff is a steep
-- part of the mountains. The costs of a block (rpg_map_costs), the climb on a move (rpg_climb_check), where a walk may
-- end (rpg_map_walk), where a creature is set down (rpg_map_set_down) and the Maps tab all read it.
WITH h AS MATERIALIZED (
       SELECT b.*, cw.rise AS w_rise, cw.difficulty AS w_dif, cw.pct AS w_pct, cr.rise AS r_rise, cr.difficulty AS r_dif, cr.pct AS r_pct
         FROM public.rpg_map_buildings(p_level, p_x0, p_y0, p_cols, p_rows) b
        CROSS JOIN LATERAL public.rpg_map_climb_by(90, b.eaves) cw
        CROSS JOIN LATERAL public.rpg_map_climb(b.pitch) cr)
SELECT gx, gy, h.id, CASE WHEN q.wall THEN 'wall' ELSE 'roof' END, CASE WHEN q.wall THEN 90 ELSE h.pitch END,
       CASE WHEN q.wall THEN h.w_rise ELSE h.r_rise END, CASE WHEN q.wall THEN h.w_dif ELSE h.r_dif END, CASE WHEN q.wall THEN h.w_pct ELSE h.r_pct END
  FROM h
 CROSS JOIN LATERAL (SELECT h.half_len * abs(h.ux) + h.half_wide * abs(h.uy) AS ex, h.half_len * abs(h.uy) + h.half_wide * abs(h.ux) AS ey) e
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(h.cx - e.ex)::integer), least(p_x0 + p_cols - 1, floor(h.cx + e.ex)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(h.cy - e.ey)::integer), least(p_y0 + p_rows - 1, floor(h.cy + e.ey)::integer)) AS gy
 -- the middle of the square, measured along the house and across it
 CROSS JOIN LATERAL (SELECT (gx + 0.5 - h.cx) * h.ux + (gy + 0.5 - h.cy) * h.uy AS a, (gy + 0.5 - h.cy) * h.ux - (gx + 0.5 - h.cx) * h.uy AS b) l
 CROSS JOIN LATERAL (SELECT abs(l.a) > h.half_len - 1 OR abs(l.b) > h.half_wide - 1 AS wall) q
 WHERE abs(l.a) <= h.half_len AND abs(l.b) <= h.half_wide;
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
-- A square a house stands on (rpg_map_building_cells; step 8c) is climbed too: its wall's or roof's percent (a wall
-- 2.6 m to the eaves +3,644%, a roof square at 50 degrees +1,818%); the ground under it keeps its kind and how hard it
-- is, and the sea stays the sea.
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
     -- houses: on the battle grid, only when the block holds the ground of a village, town or city, or of a place
     bd AS MATERIALIZED (SELECT b.x, b.y, b.pct FROM public.rpg_map_building_cells(p_level, p_x0, p_y0, p_cols, p_rows) b
                          WHERE p_level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN bd.x IS NOT NULL AND c.kind <> 'sea' THEN bd.pct
            WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
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
  LEFT JOIN bd ON bd.x = c.x AND bd.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
$function$;

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
-- The wall or the roof of a house is climbed the same way (step 8c; rpg_map_building_cells): a wall is sheer, 90
-- degrees, difficulty 10, and climbs the house's height to its eaves (a village house 2.6 m: Karen, Climbing 7, needs
-- 59; a slip drops her 2.6 m, 2 damage); a roof square climbs like rock of the roof's pitch.
-- Returns {made, text}, or nothing when the square is not a cliff and no house stands on it.
DECLARE
  v_p record; v_s record; v_c record; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer; v_made boolean;
  v_text text; v_gear boolean; v_harm integer := 0; v_roll_id uuid; v_out text; v_max integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) THEN RETURN NULL; END IF;
  -- a house on the square (step 8c): its wall or its roof; else a mountain cliff
  SELECT b.angle, b.rise, b.difficulty, b.pct, b.part INTO v_c FROM public.rpg_map_building_cells(7, p_x - 1, p_y - 1, 1, 1) b;
  IF NOT FOUND THEN
    SELECT k.angle, k.rise, k.difficulty, k.pct, NULL::text AS part INTO v_c FROM public.rpg_map_cliff(p_x, p_y) k;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;
  v_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
            AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
  v_key := CASE WHEN v_gear THEN 'climb_gear' ELSE 'CL' END;
  v_skill := public.rpg_participant_value(p_participant_id, v_key);
  PERFORM set_config('rpg.engine', 'on', true);
  IF v_p.creature_id IS NULL AND v_skill IS NOT NULL THEN
    v_r := public.rpg_roll(v_p.character_id, v_key, v_c.difficulty, CASE v_c.part WHEN 'wall' THEN 'Climbing a wall' WHEN 'roof' THEN 'Climbing a roof' ELSE 'Climbing a cliff' END, NULL, v_s.id, p_participant_id);
    v_roll := (v_r->>'roll')::integer; v_nc := jsonb_build_object('needed', v_r->'needed', 'critical', v_r->'critical'); v_roll_id := (v_r->>'roll_id')::uuid;
  ELSE
    v_nc := public.rpg_needed(coalesce(v_skill, 0), v_c.difficulty);
    v_roll := floor(random() * 100)::integer + 1;
  END IF;
  v_made := v_roll >= (v_nc->>'needed')::numeric;
  v_out := public.rpg_outcome(v_roll, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, false, 0)->>'key';
  v_text := v_p.name || ' climbs ' || CASE v_c.part WHEN 'wall' THEN 'the wall of a house' WHEN 'roof' THEN 'a ' || round(v_c.angle) || '-degree roof'
                                                    ELSE 'a ' || round(v_c.angle) || '-degree cliff' END
         || ', ' || trim_scale(round(v_c.rise::numeric, 1)) || ' m ('
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
-- The walk runs straight (rpg_map_line), or along the roads where that is quicker (step 8b, rpg_map_road_path: off a
-- road walking takes 5/3 as long, Tobler 1993): leg by leg from place to place, the ground from rpg_map_route_path,
-- looked at closer where the sea starts. A leg along a road is walked on the road: road ground (rpg_map_band road,
-- +0% to +10%), a mountain road over mountains (pass), the ground of the road card itself along a place card that is a road,
-- the streets in a village, town or city and the ground of an open place it crosses; snow and ice stay snow and ice;
-- where a road meets a river or a lake it crosses it (a bridge, a ford or a ferry), walked as the road; the sea stops
-- it. It stops:
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
--   at the end of the roads it looked at, when the square it is heading for lies farther (rpg_map_road_path stop): the
--   square it was heading for is kept, as when the day runs out, and the next turn looks again from there;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it, no house on it), stepping back along the walk
-- if it must. Houses (step 8c) are walked round, along the streets and yards between them: a walk reads a village,
-- town or city as its own ground, and climbing a house is a move on the fight board.
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
  v_wx integer[]; v_wy integer[]; v_wk integer[]; v_wp uuid[]; v_stop boolean; v_cum integer[]; v_lk integer; v_kind text; v_place uuid;
  v_onroad integer := 0; v_ex integer; v_ey integer; v_house boolean := false;
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
  -- the way: straight, or along the roads (rpg_map_road_path): its points, how each leg is walked (v_wk[i + 1] for the
  -- leg from point i to point i + 1), and the steps walked before each point
  SELECT array_agg(r.x ORDER BY r.n), array_agg(r.y ORDER BY r.n), array_agg(r.class ORDER BY r.n), array_agg(r.place ORDER BY r.n), coalesce(bool_or(r.stop), false)
    INTO v_wx, v_wy, v_wk, v_wp, v_stop
    FROM public.rpg_map_road_path(v_sx, v_sy, v_gx, v_gy) r;
  SELECT array_agg(q.c ORDER BY q.i) INTO v_cum
    FROM (SELECT g.i, coalesce(sum(l.steps) OVER (ORDER BY g.i), 0)::integer AS c
            FROM generate_series(1, cardinality(v_wx)) AS g(i)
            LEFT JOIN LATERAL public.rpg_map_line(v_wx[g.i - 1], v_wy[g.i - 1], v_wx[g.i], v_wy[g.i]) l ON g.i > 1) q;
  v_steps := v_cum[cardinality(v_cum)];
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
    FOR v_r IN SELECT * FROM public.rpg_map_route_path(v_wx, v_wy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_path_at(v_wx, v_wy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0; v_wc := 0; v_swim := false;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- on a leg along a road, the road (step 8b): road ground, also over a river or a lake (its crossing); a mountain
      -- road over mountains; the ground of a road card; the streets of a village, town or city, an open place, snow and
      -- ice and the sea stay what they are
      v_lk := v_wk[v_r.leg + 1]; v_kind := v_r.kind; v_place := v_r.place_id;
      IF v_lk = 4 AND v_kind <> 'sea' THEN v_kind := 'place'; v_place := v_wp[v_r.leg + 1];
      ELSIF v_lk IS NOT NULL AND v_kind = 'mountains' THEN v_kind := 'pass';
      ELSIF v_lk IS NOT NULL AND v_kind NOT IN ('sea', 'ice', 'town', 'place', 'pass') THEN v_kind := 'road';
      END IF;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_kind IN ('water', 'deep') OR (v_r.level < 7 AND v_lk IS NULL) THEN
        SELECT w.depth, w.line, w.current INTO v_wd, v_wl, v_wc
          FROM public.rpg_map_flow(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF v_kind = 'deep' AND v_r.level = 7 THEN
        -- water too deep to wade, on the battle grid: swum (step 7b), unless it pulls too hard to swim or the walk
        -- would end in it (then it stops at the water's edge)
        v_dif := public.rpg_map_swim_difficulty(v_wc);
        IF v_dif IS NOT NULL AND v_r.k_to < v_steps THEN v_pen := public.rpg_map_wade_pct(v_wd); v_swim := true; END IF;
      -- a road crosses rivers: only off the road is a deep river looked at closer
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep) AND v_lk IS NULL) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_kind, v_place) b;
      END IF;
      -- a cliff on the battle grid: climbed, at its climb's time
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_kind = 'mountains' AND v_r.level = 7 THEN
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
  -- at the end of the roads it looked at, short of where it is heading
  IF v_why IS NULL AND v_stop THEN v_why := 'way'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back; someone
  -- who went down in the water stays where they went down
  IF v_why = 'drown' THEN v_k := v_reach; END IF;
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_path_at(v_wx, v_wy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux),
         c AS MATERIALIZED (SELECT c.* FROM bb CROSS JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c),
         -- the houses there (step 8c), only where a village, town, city or place is
         hs AS MATERIALIZED (SELECT b.x, b.y FROM bb CROSS JOIN LATERAL public.rpg_map_building_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) b
                              WHERE EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place')))
    SELECT max(ux.k) INTO v_k
      FROM ux JOIN c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind NOT IN ('sea', 'deep')
       AND NOT EXISTS (SELECT 1 FROM hs WHERE hs.x = ux.ux AND hs.y = ux.y)
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  -- a house where the walk was heading (step 8c): it stops in front of it
  IF v_k > 0 AND v_k < v_reach AND v_why IS DISTINCT FROM 'drown' THEN
    SELECT EXISTS (SELECT 1 FROM public.rpg_map_path_at(v_wx, v_wy, v_reach) s
                    CROSS JOIN LATERAL public.rpg_map_building_cells(7, s.x, s.y, 1, 1) b) INTO v_house;
  END IF;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, (v_base + v_fixed) / 100.0);
  v_arrived := v_k = v_steps AND NOT v_stop;
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') NOT IN ('drown', 'fell') AND v_p.day_walk_ticks + v_walk >= v_day);
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone or a house is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_path_at(v_wx, v_wy, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_y END,
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
  -- a stretch a leg of the way, as far as it was walked; and how many of those legs were on a road
  FOR i IN 1 .. cardinality(v_wx) - 1 LOOP
    EXIT WHEN v_cum[i] >= v_k;
    IF v_cum[i + 1] <= v_k THEN v_ex := v_wx[i + 1]; v_ey := v_wy[i + 1]; ELSE v_ex := v_tx; v_ey := v_ty; END IF;
    PERFORM public.rpg_map_trail_add(v_p.character_id, v_wx[i] + 1, v_wy[i] + 1, v_ex + 1, v_ey + 1);
    IF v_wk[i + 1] IS NOT NULL THEN v_onroad := v_onroad + 1; END IF;
  END LOOP;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk)
                                   || CASE WHEN v_onroad > 0 THEN ' along the road' || CASE WHEN v_onroad > 1 THEN 's' ELSE '' END ELSE '' END || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'way' THEN ' The roads go on: the walk carries on from here next turn.' ELSE '' END
         || CASE WHEN v_why = 'shore' THEN ' The sea, water too rough to swim, or the water''s edge stops the walk.' ELSE '' END
         || CASE WHEN v_house THEN ' A house stands where the walk was heading: it stops in front of it.' ELSE '' END
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
                 THEN ' Still ' || public.rpg_map_length_text((SELECT l.steps FROM public.rpg_map_line(v_tx, v_ty, v_gx, v_gy) l)) || ' to go.' ELSE '' END;
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

CREATE OR REPLACE FUNCTION public.rpg_map_set_down(p_participant_id uuid, p_x integer, p_y integer, p_squares integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Puts a newly met creature on the map p_squares away from a square (world squares from 1): one of the eight ways at
-- random, on ground nobody stands on, never in the sea, in water too deep to wade (rpg_map_swim) or on a house
-- (rpg_map_building_cells; step 8c); nearer if no way is
-- free that far. Returns whether it found a square.
DECLARE v_p record; v_d integer; v_w integer; v_x integer; v_y integer; v_dir record;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  SELECT l.span INTO v_w FROM public.rpg_map_ladder() l WHERE l.level = 1;
  FOR v_d IN REVERSE greatest(p_squares, 1) .. 1 LOOP
    FOR v_dir IN SELECT d.dx, d.dy FROM (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS d(dx, dy) ORDER BY random() LOOP
      v_x := mod(p_x - 1 + v_dir.dx * v_d + v_w, v_w) + 1;
      v_y := p_y + v_dir.dy * v_d;
      CONTINUE WHEN v_y < 1 OR v_y > v_w / 2;
      CONTINUE WHEN (SELECT f.sea FROM public.rpg_fight_square(v_p.session_id, v_x, v_y) f);
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_map_swim(v_x, v_y));
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_map_building_cells(7, v_x - 1, v_y - 1, 1, 1));
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants o
                             WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = v_x AND o.pos_y = v_y
                               AND public.rpg_participant_blocks(o.id));
      UPDATE public.rpg_session_participants SET pos_x = v_x, pos_y = v_y WHERE id = p_participant_id;
      RETURN true;
    END LOOP;
  END LOOP;
  RETURN false;
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
-- (- for none). river = the biggest river drawn as a line through a cell too coarse to hold it as water (2 a great
-- river, 3 a river, 4 a stream, 5 a brook; rpg_map_rivers) with the point its line passes nearest the cell's middle,
-- in thousandths of a cell from that middle, so the line is drawn where the river truly runs at every zoom; the detail
-- carries rivers, one digit a cell (0 none), and river_x, river_y, that point as a digit 0 to 9 across the cell.
-- journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
-- towns = the villages, towns and cities the read shows (step 8; rpg_map_towns): the Country grid its cities and the
-- Region grid all three, each a mark in the cell its middle stands in (its id among the marks of that cell); on the City
-- grid and finer the cells of the ground of each (rpg_map_town_cells), which come as kind place with place = its id,
-- so they are drawn and named like a place with ground. A grid drawn fine carries them in its detail the same way.
-- Each is told as rpg_map_town_entry tells it; the Region grid lists its towns and cities.
-- roads = the roads the read draws (step 8b; rpg_map_roads): highways from the Country grid down, roads and lanes from
-- the Region grid down to the District grid (a place shown whole draws those of the grid of its detail; the battle grid has
-- them as ground of its own, road and mountain road, among its cells). Each piece of road is [size (1 highway, 2 road,
-- 3 lane), x0, y0, x1, y1] in thousandths of a cell from the top-left corner: a stretch cut to the cells it crosses
-- that are found and not sea (a road crosses rivers and lakes, by a bridge, a ford or a ferry). road_width = how wide
-- each size is, in thousandths of a cell of what is drawn.
-- houses = the houses on the battle grid (step 8c; rpg_map_buildings): each its id, roof (thatch or tile), its middle
-- (x, y in thousandths of a square from the top-left corner), the way its ridge runs ([x, y], thousandths of a step),
-- its length and width (thousandths of a square), its height to the eaves in metres, its roof's pitch in degrees and its
-- storeys. A cell a house stands on carries climb = [wall or roof, metres it climbs, degrees, difficulty of the Climbing
-- roll] (rpg_map_building_cells); its cost is the climb's. The kids login sees a house once a cell of it is found.
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

  -- the cells, read once for the villages, towns and cities on them (step 8) and for the picture
  WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows)),
       -- the kinds of the cells of a Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (3, 4)),
       -- the villages, towns and cities marked on this grid (the Country grid its cities, the Region grid all three),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT kj.k FROM kj)) t
          WHERE v_l.level IN (3, 4) AND t.kind IS NOT NULL),
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
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level, v_x0, v_y0, v_cols, v_rows) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
           LEFT JOIN public.rpg_map_steep(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
           LEFT JOIN (SELECT DISTINCT w.x, w.y
                        FROM unnest(v_known) AS n(id)
                       CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_cols, v_rows) w
                       WHERE NOT v_gm) kn ON kn.x = c.x AND kn.y = c.y
           LEFT JOIN tm ON tm.x = c.x AND tm.y = c.y
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
                   'marks', CASE WHEN cl.seen AND (cardinality(cl.marks) > 0 OR cl.towns IS NOT NULL) THEN to_jsonb(cl.marks) || coalesce(cl.towns, '[]'::jsonb) END,
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
                   'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || cl.wx::text || '-' || cl.y::text END,
                   'to', jsonb_build_array(cl.wx::bigint * v_l.cell + v_l.cell / 2 + 1, cl.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
                 ORDER BY cl.y, cl.x)
            FROM cl),
         -- the villages, towns and cities shown: a mark on a cell that is seen, or ground on one
         (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1,
                                                     v_l.level = 4 AND q.kind IN ('town', 'city'), q.ground)
                           ORDER BY q.n, q.name)
            FROM (SELECT tw.id, tw.kind, tw.name, tw.people, tw.x, tw.y, tw.r, array_position(ARRAY['city', 'town', 'village'], tw.kind) AS n, gt.g AS ground
                    FROM tw CROSS JOIN gt JOIN cl ON cl.x = floor(tw.x::double precision / v_l.cell)::integer AND cl.y = floor(tw.y::double precision / v_l.cell)::integer
                   WHERE cl.seen
                  UNION ALL
                  SELECT DISTINCT ON (tg.id) tg.id, tg.kind, tg.name, tg.people, tg.tx, tg.ty, tg.r, array_position(ARRAY['city', 'town', 'village'], tg.kind), gt.g
                    FROM tg CROSS JOIN gt JOIN cl ON cl.x = tg.x AND cl.y = tg.y
                   WHERE cl.seen AND cl.town IS NOT NULL) q),
         -- what grows at the sites of this grid, for its roads
         (SELECT jsonb_object_agg(tw.id, tw.kind) FROM tw),
         -- where a road is drawn (step 8b): found, and not the sea
         (SELECT jsonb_object_agg(cl.x || ',' || cl.y, 1) FROM cl WHERE cl.seen AND cl.kind <> 'sea'),
         -- the houses with a square that is seen (step 8c)
         (SELECT array_agg(DISTINCT cl.house) FROM cl WHERE cl.seen AND cl.house IS NOT NULL)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen;

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
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
             LEFT JOIN dm ON dm.x = c.x AND dm.y = c.y
             LEFT JOIN dg ON dg.x = c.x AND dg.y = c.y),
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
                              'marks', (SELECT jsonb_object_agg((d.x - v_x0 * v_sub)::text || ',' || (d.y - v_y0 * v_sub)::text, to_jsonb(d.marks) || coalesce(d.towns, '[]'::jsonb))
                                          FROM d WHERE d.seen AND (cardinality(d.marks) > 0 OR d.towns IS NOT NULL))),
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
           (SELECT jsonb_object_agg(d.x || ',' || d.y, 1) FROM d WHERE d.seen AND d.kind <> 'sea')
      INTO v_detail, v_dtowns, v_dkinds, v_dshown
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
                      coalesce(CASE WHEN v_detail IS NULL THEN v_shown ELSE v_dshown END, '{}'::jsonb) AS shown),
         lg AS (SELECT row_number() OVER () AS n, r.*
                  FROM public.rpg_map_roads(CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_l.level ELSE v_l.level + 1 END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_x0 ELSE v_x0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_y0 ELSE v_y0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_cols ELSE v_dc END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_rows ELSE v_dr END,
                                            v_what, CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_kinds ELSE v_dkinds END, 0) r),
         -- each stretch in cells of what is drawn, from its first cell
         lc AS (SELECT lg.n, lg.class, lg.ax / g.cell - g.x0 AS u0, lg.ay / g.cell - g.y0 AS v0, lg.bx / g.cell - g.x0 AS u1, lg.by / g.cell - g.y0 AS v1,
                       g.x0, g.y0, g.cols, g.rows, g.shown
                  FROM lg CROSS JOIN g),
         -- the part of the stretch inside each cell it crosses (t0 to t1: 0 at its start, 1 at its end), where a road of
         -- its size is drawn
         ct AS (SELECT lc.n, lc.class, lc.u0, lc.v0, lc.u1, lc.v1, greatest(0, tx.lo, ty.lo) AS t0, least(1, tx.hi, ty.hi) AS t1
                  FROM lc
                 CROSS JOIN LATERAL generate_series(greatest(floor(least(lc.u0, lc.u1))::integer, 0), least(floor(greatest(lc.u0, lc.u1))::integer, lc.cols - 1)) AS i
                 CROSS JOIN LATERAL generate_series(greatest(floor(least(lc.v0, lc.v1))::integer, 0), least(floor(greatest(lc.v0, lc.v1))::integer, lc.rows - 1)) AS j
                 CROSS JOIN LATERAL (SELECT CASE WHEN lc.u1 = lc.u0 THEN 0 ELSE least((i - lc.u0) / (lc.u1 - lc.u0), (i + 1 - lc.u0) / (lc.u1 - lc.u0)) END AS lo,
                                            CASE WHEN lc.u1 = lc.u0 THEN 1 ELSE greatest((i - lc.u0) / (lc.u1 - lc.u0), (i + 1 - lc.u0) / (lc.u1 - lc.u0)) END AS hi) tx
                 CROSS JOIN LATERAL (SELECT CASE WHEN lc.v1 = lc.v0 THEN 0 ELSE least((j - lc.v0) / (lc.v1 - lc.v0), (j + 1 - lc.v0) / (lc.v1 - lc.v0)) END AS lo,
                                            CASE WHEN lc.v1 = lc.v0 THEN 1 ELSE greatest((j - lc.v0) / (lc.v1 - lc.v0), (j + 1 - lc.v0) / (lc.v1 - lc.v0)) END AS hi) ty
                 WHERE greatest(0, tx.lo, ty.lo) < least(1, tx.hi, ty.hi)
                   AND lc.shown ? ((i + lc.x0) || ',' || (j + lc.y0))),
         -- the parts that follow on from one another make one piece
         pt AS (SELECT ct.*, CASE WHEN ct.t0 > coalesce(max(ct.t1) OVER (PARTITION BY ct.n ORDER BY ct.t0 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), -1) + 1e-9
                                  THEN 1 ELSE 0 END AS gap
                  FROM ct),
         pc AS (SELECT pt.*, sum(pt.gap) OVER (PARTITION BY pt.n ORDER BY pt.t0) AS run FROM pt)
    SELECT jsonb_agg(jsonb_build_array(q.class, round(q.x0 * 1000)::integer, round(q.y0 * 1000)::integer, round(q.x1 * 1000)::integer, round(q.y1 * 1000)::integer)
                     ORDER BY q.class DESC, q.n, q.run)
      INTO v_roads
      FROM (SELECT pc.n, pc.run, min(pc.class) AS class,
                   (min(pc.u0) + min(pc.t0) * (min(pc.u1) - min(pc.u0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS x0,
                   (min(pc.v0) + min(pc.t0) * (min(pc.v1) - min(pc.v0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS y0,
                   (min(pc.u0) + max(pc.t1) * (min(pc.u1) - min(pc.u0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS x1,
                   (min(pc.v0) + max(pc.t1) * (min(pc.v1) - min(pc.v0))) / (CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END) AS y1
              FROM pc GROUP BY pc.n, pc.run) q;
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
    'houses', coalesce(v_houses, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

UPDATE public.rpg_rules SET body = replace(body,
'The battle grid draws its rock face. Buildings will be climbed the same way once towns come.',
'The battle grid draws its rock face.'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'climbing' AND position('Buildings will be climbed the same way once towns come.' IN body) > 0;
UPDATE public.rpg_rules SET body = replace(body,
'From an 80-degree square, 6.3 m: 41 × (6.3 ÷ 15)² = 7.3, so 8.*',
'From an 80-degree square, 6.3 m: 41 × (6.3 ÷ 15)² = 7.3, so 8.*

Houses are climbed the same way. The squares along the edge of a house are its walls, sheer at 90 degrees: difficulty 10, and a wall climbs the height of the house to its eaves, 2.4 to 2.9 m a storey. The squares inside are its roof, which climbs like rock of its pitch: thatch 45 to 55 degrees (difficulty 1.4 to 3.6), clay tiles 40 to 50 degrees (0.3 to 2.5), each square 0.9 to 1.6 m up. A slip off a wall falls the whole height.
*Karen (Climbing 7) at the 2.6 m wall of a village house needs 100 × 10 ÷ (10 + 7) = 59 or more. The climb takes 2.6 m at 300 m an hour, 187 ticks at Speed 10. A slip drops her 2.6 m: 41 × (2.6 ÷ 15)² = 1.2, so 2 damage.*'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'climbing' AND position('Houses are climbed the same way.' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'A longer walk picks its way round the cliffs; the mountains'' own +200% to +500% allows for that.',
'A longer walk picks its way round the cliffs; the mountains'' own +200% to +500% allows for that. Any walk goes round houses, along the streets and yards between them, and never ends on one; climbing a house is a move on the fight board.'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'climbing' AND position('Any walk goes round houses' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'and closer grids their streets and yards, +0% to +10% time a square like open land.',
'and closer grids their streets and yards, +0% to +10% time a square like open land. On the battle grid their houses stand along the roads that run through them, one household of 4.5 people to a house, in plots that share both sides of the streets among the households, within the widths medieval surveyors laid out: a village toft 2 to 4 perches (10 to 20 m), a town burgage 1.5 to 2.5 perches, a city plot 1 to 1.5 (a perch is 5 m). A village house is 4 to 5.5 m wide and 2 to 4 bays long (a bay is 4.6 m), one storey under thatch; a town house fills its plot and runs 2 to 3 bays back, two storeys under clay tiles; a city house has two or three. A village whose middle only one lane reaches has its street run on through the middle. Houses are climbed (see Climbing); a walk goes round them.'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('their houses stand along the roads' IN body) = 0;
UPDATE public.rpg_rules SET body = replace(body,
'is a cliff that has to be climbed, a Climbing roll and far more time (see Climbing).',
'is a cliff that has to be climbed, a Climbing roll and far more time, and so is every wall and roof of a house (see Climbing).'), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('every wall and roof of a house' IN body) = 0;

