-- Roleplaying world map step 3 of Peter's 2026-10-07 22:51 queue (his 21:05 ask: "the battle grids in a city should still look like you
-- are fighting in the streets or in buildings"): a market place at the middle of every town and city, streets behind its main road
-- and lanes across them, paved on the battle grid and drawn on the District grid; buildings on the battle grid as floor plans,
-- walls climbed, doors and floors walked. No drops, no new tables; new functions rpg_map_town_grounds, rpg_map_town_streets,
-- rpg_map_street_cells, rpg_map_building_squares; 27 new settings. The saved map is cleared at the end (the battle grid's ground and
-- the District grids' buildings change).

-- Roleplaying world map step 3 of Peter's 2026-10-07 22:51 queue (his 21:05 ask: battle grids in a city should look
-- like fighting in the streets or inside buildings): streets inside every town and city, a market place at the
-- middle, paved streets and building insides on the battle grid.
-- The settings. Three new sizes of way, read by rpg_map_road_lines like the roads (map_road_<size>_width in squares,
-- map_road_<size>_wander the share of a bend it swings): 4 the market place, 5 a street, 6 a lane. Widths: a medieval
-- town's back streets ran about 4 to 6 m, its lanes and vennels 2 to 3 m (Keene 1985, Survey of Medieval Winchester;
-- Schofield and Vince 2003, Medieval Towns). Planned streets ran straight (Lilley 2009, City and Cosmos; Beresford 1967,
-- New Towns of the Middle Ages: Winchelsea, Salisbury's chequers), lanes wandered a little.
INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_4_width', 22, 'Town streets: how wide a market place is drawn by the road line, in squares (its own width is rolled, map_street_market_wide_*); used for the finest bend only'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_4_wander', 0, 'Town streets: a market place runs straight'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_5_width', 4.5, 'Town streets: how wide a street inside a town or city is, in squares (about 5 m)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_5_wander', 0, 'Town streets: a street inside a town runs straight, as planned streets did'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_6_width', 2.5, 'Town streets: how wide a lane between two streets is, in squares (about 2.8 m)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_road_6_wander', 0.04, 'Town streets: how far a lane wanders, as a share of its bend'),
 -- the market place: a widened street at the middle, along the main road (Slater 1987 and Britnell 1996 on English
 -- market places: a street widened to 20 to 40 m for a few hundred feet, or a triangle where roads meet)
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_town_low', 60, 'Market place: shortest in a town, metres along the main road'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_town_high', 110, 'Market place: longest in a town, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_city_low', 90, 'Market place: shortest in a city, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_city_high', 160, 'Market place: longest in a city, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_great_city_low', 120, 'Market place: shortest in a great city, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_len_great_city_high', 220, 'Market place: longest in a great city, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_town_low', 16, 'Market place: narrowest in a town, metres across'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_town_high', 26, 'Market place: widest in a town, metres across'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_city_low', 20, 'Market place: narrowest in a city, metres across'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_city_high', 34, 'Market place: widest in a city, metres across'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_great_city_low', 26, 'Market place: narrowest in a great city, metres across'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_market_wide_great_city_high', 40, 'Market place: widest in a great city, metres across'),
 -- the streets behind the main road: parallel to it, as many as the households need frontage for, crossed by lanes
 -- (Conzen 1960 on Alnwick: plot series between a main street and its back lane, 60 to 100 m deep; Slater 1981 on
 -- burgage series; Salisbury's chequers about 100 m a side)
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_gap_low', 50, 'Town streets: closest two parallel streets may be, metres (two rows of houses back to back with short yards)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_gap_high', 100, 'Town streets: farthest apart two parallel streets are, metres (Salisbury''s chequers about 100 m a side; burgage plots 60 to 100 m deep)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_cross_low', 1.5, 'Town streets: lanes across the streets are this many times as far apart as the streets, at least'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_cross_high', 2.5, 'Town streets: lanes across the streets are this many times as far apart as the streets, at most'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_min_m', 30, 'Town streets: the shortest piece of street or lane laid, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_edge_m', 3, 'Town streets: how far inside the edge of the town ground a street stops, metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_churchyard_m', 4, 'Town streets: how far from a church''s walls a street or lane inside the town stops (its churchyard), metres'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_street_close_m', 20, 'Town streets: how much more than its own reach a cathedral close keeps clear of streets, metres'),
 -- building insides (Peter 2026-10-07 21:05: fighting inside buildings)
 ('126794dd-25ff-47d2-a436-724499733365', 'map_house_door_m', 1.2, 'Building insides: how wide a door is, metres (a barn''s cart doors twice that)')
ON CONFLICT (agency_id, key) DO NOTHING;

-- (step 3, streets) The villages, towns and cities whose ground reaches a box of the battle grid: the one home of that
-- list, read by rpg_map_buildings (the houses) and rpg_map_street_cells (the streets). Moved here unchanged from
-- rpg_map_buildings.
CREATE OR REPLACE FUNCTION public.rpg_map_town_grounds(p_x0 double precision, p_y0 double precision, p_x1 double precision, p_y1 double precision)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The villages, towns and cities whose ground can reach the box p_x0, p_y0 to p_x1, p_y1 (world squares of the
-- battle grid): the rolled ones (rpg_map_towns), and the place cards of a village, town or city (their oval grown by
-- how far their edge may wander, rpg_map_grown; the copy nearest the box). Each: town (its id), kind, mx, my (its
-- middle), r and shape (a rolled one's edge, rpg_map_town_edge), card (a card's id), people (a rolled one's count),
-- cw, ch (a card's half width and height), fx, fy (how far its ground may reach from its middle each way).
WITH g AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_edge_share')::double precision AS share,
                  (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1)::double precision AS world)
SELECT coalesce(jsonb_agg(q), '[]')
  FROM g CROSS JOIN LATERAL (
        SELECT t.id AS town, t.kind, t.x::double precision AS mx, t.y::double precision AS my, t.r, t.shape, NULL::uuid AS card, t.people,
               NULL::double precision AS cw, NULL::double precision AS ch,
               t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fx, t.r * (1 + abs(t.shape[1]) + abs(t.shape[3]) + abs(t.shape[5])) AS fy
          FROM public.rpg_map_towns(7, floor(p_x0)::integer, floor(p_y0)::integer, (ceil(p_x1) - floor(p_x0))::integer, (ceil(p_y1) - floor(p_y0))::integer, NULL) t
         WHERE t.kind IS NOT NULL
        UNION ALL
        SELECT c.id::text, c.place_icon, c.place_x + g.world * floor(((p_x0 + p_x1) / 2 - c.place_x) / g.world + 0.5), c.place_y, NULL, NULL, c.id, NULL,
               c.place_w / 2.0, c.place_h / 2.0,
               public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share) / 2.0, public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share) / 2.0
          FROM public.rpg_creatures c
         WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
           AND c.place_penalty IS NOT NULL AND c.place_icon IN ('village', 'town', 'city')
           AND public.rpg_map_touches(p_x0, p_y0, p_x1, p_y1, c.place_x, c.place_y,
                                      public.rpg_map_grown(c.place_w, c.place_w, c.place_h, g.share),
                                      public.rpg_map_grown(c.place_h, c.place_w, c.place_h, g.share), g.world::integer)) q;
$function$;

-- (step 3, streets) The streets of every village, town and city: the one home of where they run and of each
-- settlement's plot width. Moved out of rpg_map_buildings (its roads part unchanged) and grown with the market place,
-- the streets and lanes behind the main road, and the cathedral close.
CREATE OR REPLACE FUNCTION public.rpg_map_town_streets(p_tw jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- For each settlement in p_tw (as rpg_map_town_grounds lists them), its streets and plot width, worked out once a
-- transaction and kept in the setting rpg.townstreets (by settlement id); returns the entries of those asked for.
-- An entry: f (the plot width, in squares), people, plots (how many plots both sides of its streets hold), main (the
-- line whose first plot on the left is the main plot, where the main church stands), close (a great city's cathedral:
-- j the try it stands at, x, y its middle; or null) and lines, each a street plots line: k (its order), class (1
-- highway, 2 road, 3 lane between places; 4 the market place, 5 a street, 6 a lane inside the town), ax, ay, bx, by
-- (its ends), a, b (their ids, which key its bends), len, t0 (how far along it passes nearest the middle), half (half
-- its width), lo, hi (how far along it houses may stand) and pts (its points: n, s along the straight line, x, y).
--
-- The roads (as before, step 8c): every road whose line may cross the settlement, each where it comes near (24 points
-- to its finest bend), lined with plots from where it passes nearest the middle; a middle only one road reaches lets
-- that road run on through to the far side.
--
-- Inside a town, city or great city (Peter 2026-10-07 21:05: battle grids in a city should look like fighting in the
-- streets; a city of 10,000 had about 7 street lines and room for 1,300 plots for its 2,400 households):
--   the market place: the main road (its first, the biggest) widened at the middle, map_street_market_len_<kind>_* long
--     and map_street_market_wide_<kind>_* across (rolled at the middle square, part 12, layers 1281 and 1282), lined
--     with plots like a street; its first plot on the left is the main plot (Slater 1987, Britnell 1996: the market
--     place was a widened street at the heart of the town, its church on it);
--   streets behind the main road, parallel to it, and lanes across them (Conzen 1960, Slater 1981: plot series with
--     back lanes behind them; Lilley 2009, Beresford 1967: planned towns laid on a grid). As much street as the
--     households need frontage for: households (people over map_house_people) times the middle plot width of its kind,
--     over two (a plot each side), less the roads and the market place already there; the streets that much apart
--     on average over the ground the town covers (its area, from its edge at 72 angles) with the lanes c times as far
--     apart (c rolled from map_street_cross_*, layer 1283), so the average gap G = area x (1 + 1/c) / length needed,
--     held inside map_street_gap_low to _high. Built closest at the middle and loosest at the edge (Conzen 1960: the
--     plots near the market filled in first; the burgage cycle): the gap at a distance d from the main road is
--     map_street_gap_low + 2 (G - low) d / R (R = how far the ground reaches), never past _high, so on average it is
--     G again; the lanes the same, c times as far apart. A settlement whose roads and market already give its
--     households their frontage gets none. Each street and lane runs as far as the ground does (to map_street_edge_m inside its edge), in
--     pieces where the edge cuts it, none shorter than map_street_min_m. Streets run straight; lanes wander a little
--     (map_road_6_wander).
--   a great city's cathedral (step 14e) stands in its own close: tried as before (the three widest gaps between the
--     roads that leave the middle, then the eight points of the compass, at map_house_cathedral_close_tries distances,
--     the nearest clear of the roads and the market place and with no water in the District cells under it), now once
--     a settlement here rather than for every block; the streets and lanes keep out of its close (its reach and
--     map_street_close_m more, and how far a lane may wander).
-- Villages keep their one street (the lane through them).
#variable_conflict use_column
DECLARE
  v_tl   jsonb;
  v_out  jsonb := '{}';
  v_new  jsonb;
  v_j    jsonb;
  g      record;
  t      record;
  v_roads jsonb;
  v_lines jsonb;
  v_len  double precision;
  v_people double precision;
  v_px double precision; v_py double precision; v_ux double precision; v_uy double precision;
  v_mlen double precision; v_mwide double precision;
  v_area double precision; v_need double precision; v_gap double precision; v_c double precision;
  v_reach double precision;
  v_close jsonb;
  v_main integer;
  v_extra jsonb;
  v_grid jsonb;
  v_offs double precision[];
  v_coffs double precision[];
  v_o double precision;
  v_k double precision;
BEGIN
  v_tl := coalesce(nullif(current_setting('rpg.townstreets', true), ''), '{}')::jsonb;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_tw) e WHERE NOT v_tl ? (e ->> 'town')) THEN
    RETURN (SELECT coalesce(jsonb_object_agg(e ->> 'town', v_tl -> (e ->> 'town')), '{}') FROM jsonb_array_elements(p_tw) e);
  END IF;
  v_j := (SELECT jsonb_object_agg(s.key, s.value) FROM public.rpg_settings s
           WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
             AND (s.key LIKE 'map\_house\_%' OR s.key LIKE 'map\_street\_%' OR s.key LIKE 'map\_road\__\_width' OR s.key LIKE 'map\_road\__\_wander'
                  OR s.key IN ('map_square_m', 'map_seed')));
  SELECT (v_j ->> 'map_square_m')::double precision AS sq, (v_j ->> 'map_seed')::integer AS seed,
         (v_j ->> 'map_house_perch_m')::double precision AS perch, (v_j ->> 'map_house_people')::double precision AS household,
         (v_j ->> 'map_road_1_width')::double precision AS w1, (v_j ->> 'map_road_2_width')::double precision AS w2,
         (v_j ->> 'map_road_3_width')::double precision AS w3, (v_j ->> 'map_road_5_width')::double precision AS w5,
         (v_j ->> 'map_road_6_width')::double precision AS w6, (v_j ->> 'map_road_6_wander')::double precision AS wander6,
         (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 6)::double precision AS dc
    INTO g;

  FOR t IN SELECT * FROM jsonb_to_recordset(p_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision, shape double precision[],
                                                     card uuid, people integer, cw double precision, ch double precision, fx double precision, fy double precision) LOOP
    CONTINUE WHEN v_tl ? t.town OR v_out ? t.town;
    -- every road whose line may cross it (rpg_map_roads over the whole settlement), in a steady order; the line of
    -- each where it comes near the settlement (rpg_map_road_lines, 24 points to its finest bend, so the pieces
    -- between them lie on the road to a few hundredths of a square: n = which point, s = how far along the straight
    -- line between its ends, x, y where the road is), where it passes nearest the middle (t0, along the straight
    -- line from a), the half width of its street, and how far along it houses may stand (lo to hi): the road
    -- itself, and for the one road at a middle no other road reaches, on through the middle to the far side
    WITH rl AS MATERIALIZED (
           SELECT r.class, r.ax, r.ay, r.bx, r.by, r.a, r.b, row_number() OVER (ORDER BY r.class, r.a, r.b, r.ax, r.ay) AS k
             FROM public.rpg_map_roads(7, floor(t.mx - t.fx)::integer, floor(t.my - t.fy)::integer,
                                       (ceil(2 * t.fx) + 2)::integer, (ceil(2 * t.fy) + 2)::integer, 7, NULL, 0) r),
         ra AS (SELECT array_agg(rl.class ORDER BY rl.k) AS class, array_agg(rl.ax ORDER BY rl.k) AS ax, array_agg(rl.ay ORDER BY rl.k) AS ay,
                       array_agg(rl.bx ORDER BY rl.k) AS bx, array_agg(rl.by ORDER BY rl.k) AS by, array_agg(rl.a ORDER BY rl.k) AS a, array_agg(rl.b ORDER BY rl.k) AS b
                  FROM rl HAVING count(*) > 0),
         lp AS MATERIALIZED (
           SELECT p.i AS k, p.n, p.s, p.x, p.y, p.rest
             FROM ra CROSS JOIN LATERAL public.rpg_map_road_lines(ra.class, ra.ax, ra.ay, ra.bx, ra.by, ra.a, ra.b, 1, NULL,
                                                                  t.mx - t.fx - g.w1, t.my - t.fy - g.w1, t.mx + t.fx + g.w1, t.my + t.fy + g.w1, 24) p),
         ln AS MATERIALIZED (
           SELECT rl.k, rl.class, rl.ax, rl.ay, rl.bx, rl.by, rl.a, rl.b, l0.len,
                  coalesce((SELECT lp.s FROM lp WHERE lp.k = rl.k ORDER BY power(lp.x - t.mx, 2) + power(lp.y - t.my, 2) LIMIT 1),
                           (t.mx - rl.ax) * (rl.bx - rl.ax) / l0.len + (t.my - rl.ay) * (rl.by - rl.ay) / l0.len) AS t0,
                  CASE rl.class WHEN 1 THEN g.w1 WHEN 2 THEN g.w2 ELSE g.w3 END / 2 AS half,
                  sqrt(power(rl.ax - t.mx, 2) + power(rl.ay - t.my, 2)) < 1 AS at_a,
                  sqrt(power(rl.bx - t.mx, 2) + power(rl.by - t.my, 2)) < 1 AS at_b
             FROM rl
            CROSS JOIN LATERAL (SELECT sqrt(power(rl.bx - rl.ax, 2) + power(rl.by - rl.ay, 2)) AS len) l0
            WHERE l0.len > 0 AND EXISTS (SELECT 1 FROM lp WHERE lp.k = rl.k)),
         lr AS MATERIALIZED (
           SELECT ln.*,
                  CASE WHEN ln.at_a AND m.n = 1 THEN -greatest(t.fx, t.fy) ELSE 0 END AS lo,
                  CASE WHEN ln.at_b AND m.n = 1 THEN ln.len + greatest(t.fx, t.fy) ELSE ln.len END AS hi
             FROM ln CROSS JOIN (SELECT count(*) FILTER (WHERE q.at_a OR q.at_b) AS n FROM ln q) m),
         -- how much road runs through it: every line, measured four squares at a time where it lies on the
         -- settlement's ground (a card's plain oval for this sum)
         sl AS (
           SELECT count(*) * 4 AS len
             FROM lr
            CROSS JOIN LATERAL (SELECT greatest(lr.lo, lr.t0 - greatest(t.fx, t.fy)) AS ts, least(lr.hi, lr.t0 + greatest(t.fx, t.fy)) AS te) e
            CROSS JOIN LATERAL (SELECT array_agg(e.ts + 4 * i + 2 ORDER BY i) AS s FROM generate_series(0, greatest(floor((e.te - e.ts) / 4)::integer - 1, -1)) AS i) q
            CROSS JOIN LATERAL public.rpg_map_road_line(lr.class, lr.ax, lr.ay, lr.bx, lr.by, lr.a, lr.b, 1, q.s) p
            WHERE q.s IS NOT NULL
              AND CASE WHEN t.card IS NULL
                       THEN sqrt(power(p.x - t.mx, 2) + power(p.y - t.my, 2)) <= public.rpg_map_town_edge(atan2(p.y - t.my, p.x - t.mx), t.r, t.shape)
                       ELSE power((p.x - t.mx) / t.cw, 2) + power((p.y - t.my) / t.ch, 2) <= 1 END)
    SELECT (SELECT sl.len FROM sl),
           coalesce((SELECT jsonb_agg(jsonb_build_object('k', lr.k, 'class', lr.class, 'ax', lr.ax, 'ay', lr.ay, 'bx', lr.bx, 'by', lr.by,
                                                         'a', lr.a, 'b', lr.b, 'len', lr.len, 't0', lr.t0, 'half', lr.half, 'lo', lr.lo, 'hi', lr.hi,
                                                         'pts', (SELECT jsonb_agg(jsonb_build_array(lp.n, round(lp.s::numeric, 2), round(lp.x::numeric, 2), round(lp.y::numeric, 2)) ORDER BY lp.n)
                                                                   FROM lp WHERE lp.k = lr.k)) ORDER BY lr.k)
                       FROM lr), '[]'::jsonb)
      INTO v_len, v_roads;
    -- its people: a rolled settlement's own count; a card's ground at its kind's crowding (map_<kind>_density)
    v_people := coalesce(t.people::double precision,
                         pi() * t.cw * t.ch * g.sq * g.sq / 10000 * (SELECT s.value FROM public.rpg_settings s
                                                                       WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_' || t.kind || '_density'));
    v_lines := v_roads;
    v_main := CASE WHEN jsonb_array_length(v_roads) > 0 THEN 1 END;
    v_close := NULL;
    v_len := coalesce(v_len, 0);

    IF t.kind IN ('town', 'city', 'great_city') AND jsonb_array_length(v_roads) > 0 THEN
      -- where the main road (its first) passes nearest the middle, and the way it runs there
      SELECT q.x, q.y, q.ux, q.uy INTO v_px, v_py, v_ux, v_uy
        FROM (SELECT p.x, p.y, nx.x - pv.x AS dx, nx.y - pv.y AS dy
                FROM jsonb_array_elements(v_roads -> 0 -> 'pts') WITH ORDINALITY AS e(v, o)
               CROSS JOIN LATERAL (SELECT (e.v ->> 2)::double precision AS x, (e.v ->> 3)::double precision AS y) p
               CROSS JOIN LATERAL (SELECT (coalesce(v_roads -> 0 -> 'pts' -> (e.o::integer), e.v) ->> 2)::double precision AS x,
                                          (coalesce(v_roads -> 0 -> 'pts' -> (e.o::integer), e.v) ->> 3)::double precision AS y) nx
               CROSS JOIN LATERAL (SELECT (coalesce(v_roads -> 0 -> 'pts' -> greatest(e.o::integer - 2, 0), e.v) ->> 2)::double precision AS x,
                                          (coalesce(v_roads -> 0 -> 'pts' -> greatest(e.o::integer - 2, 0), e.v) ->> 3)::double precision AS y) pv
               ORDER BY power(p.x - t.mx, 2) + power(p.y - t.my, 2) LIMIT 1) z
       CROSS JOIN LATERAL (SELECT z.x, z.y, z.dx / nullif(sqrt(z.dx * z.dx + z.dy * z.dy), 0) AS ux, z.dy / nullif(sqrt(z.dx * z.dx + z.dy * z.dy), 0) AS uy) q;
      IF v_ux IS NULL THEN
        v_ux := ((v_roads -> 0 ->> 'bx')::double precision - (v_roads -> 0 ->> 'ax')::double precision) / (v_roads -> 0 ->> 'len')::double precision;
        v_uy := ((v_roads -> 0 ->> 'by')::double precision - (v_roads -> 0 ->> 'ay')::double precision) / (v_roads -> 0 ->> 'len')::double precision;
      END IF;
      -- the market place, rolled at the middle square
      v_mlen := ((v_j ->> ('map_street_market_len_' || t.kind || '_low'))::double precision
                 + ((v_j ->> ('map_street_market_len_' || t.kind || '_high'))::double precision - (v_j ->> ('map_street_market_len_' || t.kind || '_low'))::double precision)
                   * (public.rpg_map_roll(g.seed, 1281, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0) / g.sq;
      v_mwide := ((v_j ->> ('map_street_market_wide_' || t.kind || '_low'))::double precision
                  + ((v_j ->> ('map_street_market_wide_' || t.kind || '_high'))::double precision - (v_j ->> ('map_street_market_wide_' || t.kind || '_low'))::double precision)
                    * (public.rpg_map_roll(g.seed, 1282, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0) / g.sq;
      v_extra := jsonb_build_array(jsonb_build_object('k', 50, 'class', 4, 'ax', v_px - v_ux * v_mlen / 2, 'ay', v_py - v_uy * v_mlen / 2,
                                                      'bx', v_px + v_ux * v_mlen / 2, 'by', v_py + v_uy * v_mlen / 2,
                                                      'a', t.town || ':m:a', 'b', t.town || ':m:b', 'half', v_mwide / 2));
      v_main := 50;

      -- a great city's cathedral close: the nearest try clear of the roads and the market place, with no water under it
      IF t.kind = 'great_city' THEN
        WITH lr AS (SELECT (l ->> 'k')::integer AS k, (l ->> 'class')::integer AS class, (l ->> 'ax')::double precision AS ax, (l ->> 'ay')::double precision AS ay,
                           (l ->> 'bx')::double precision AS bx, (l ->> 'by')::double precision AS by, (l ->> 'len')::double precision AS len,
                           (l ->> 't0')::double precision AS t0, (l ->> 'half')::double precision AS half, l -> 'pts' AS pts
                      FROM jsonb_array_elements(v_roads) l),
             -- the pieces of the roads, and the market place as one piece
             sg AS (SELECT q.half, q.x0, q.y0, q.x1, q.y1
                      FROM (SELECT lr.half, (e.v ->> 2)::double precision AS x0, (e.v ->> 3)::double precision AS y0,
                                   lead((e.v ->> 2)::double precision) OVER w AS x1, lead((e.v ->> 3)::double precision) OVER w AS y1,
                                   (e.v ->> 0)::integer AS n, lead((e.v ->> 0)::integer) OVER w AS n1
                              FROM lr CROSS JOIN LATERAL jsonb_array_elements(lr.pts) AS e(v)
                            WINDOW w AS (PARTITION BY lr.k ORDER BY (e.v ->> 0)::integer)) q
                     WHERE q.n1 = q.n + 1
                    UNION ALL
                    SELECT v_mwide / 2, v_px - v_ux * v_mlen / 2, v_py - v_uy * v_mlen / 2, v_px + v_ux * v_mlen / 2, v_py + v_uy * v_mlen / 2),
             ka AS (
               SELECT atan2(d.s * (lr.by - lr.ay), d.s * (lr.bx - lr.ax)) AS th
                 FROM lr CROSS JOIN (VALUES (1), (-1)) AS d(s)
                WHERE (d.s = 1 AND lr.t0 < lr.len - 1) OR (d.s = -1 AND lr.t0 > 1)),
             kg AS (
               SELECT r.th, r.gr
                 FROM (SELECT q.th + q.gap / 2 AS th, row_number() OVER (ORDER BY q.gap DESC, q.th) AS gr
                         FROM (SELECT ka.th, coalesce(lead(ka.th) OVER w, first_value(ka.th) OVER w + 2 * pi()) - ka.th AS gap
                                 FROM ka WINDOW w AS (ORDER BY ka.th)) q) r
                WHERE r.gr <= 3
               UNION ALL
               SELECT c.n * pi() / 4, 3 + c.n + 1 FROM generate_series(0, 7) AS c(n) WHERE EXISTS (SELECT 1 FROM ka)),
             kr AS (
               SELECT kg.th, kg.gr,
                      (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + n, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0 ORDER BY n)
                         FROM generate_series(1, 9) AS n) AS u,
                      (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + n, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0 ORDER BY n)
                         FROM generate_series(1, 12) AS n) AS v
                 FROM kg),
             kc AS (
               SELECT kr.*, (tn.n - 1) * 11 + kr.gr AS j, ((1 + 0.2 * (tn.n - 1)) * e.reach) / g.sq AS d, e.reach
                 FROM kr
                CROSS JOIN LATERAL (SELECT max(sqrt(power(abs(z.ex) + z.len / 2, 2) + power(abs(z.ey) + z.wide / 2, 2))) AS reach
                                      FROM public.rpg_map_church_plan('cathedral', t.kind, kr.u::double precision[], kr.v::double precision[], v_j) z) e
                CROSS JOIN LATERAL generate_series(1, (v_j ->> 'map_house_cathedral_close_tries')::integer) AS tn(n)),
             -- its parts in squares at each try (as rpg_map_buildings lays a cathedral: ex east, ey south of its middle)
             kp AS (
               SELECT kc.j, kc.d, kc.th, kc.reach, t.mx + kc.d * cos(kc.th) + c.ex / g.sq AS cx, t.my + kc.d * sin(kc.th) + c.ey / g.sq AS cy,
                      CASE WHEN c.ridge_ew THEN 1 ELSE 0 END AS rx, CASE WHEN c.ridge_ew THEN 0 ELSE 1 END AS ry,
                      c.len / 2 / g.sq AS hl, c.wide / 2 / g.sq AS hw
                 FROM kc CROSS JOIN LATERAL public.rpg_map_church_plan('cathedral', t.kind, kc.u::double precision[], kc.v::double precision[], v_j) c),
             kl AS (
               SELECT kp.j, bool_and(NOT EXISTS (
                        SELECT 1 FROM sg
                         CROSS JOIN LATERAL (SELECT sg.half - 0.01 AS wide) w
                         CROSS JOIN LATERAL (SELECT sg.x0 - kp.cx AS x0, sg.y0 - kp.cy AS y0, sg.x1 - kp.cx AS x1, sg.y1 - kp.cy AS y1) e
                         WHERE least(sg.x0, sg.x1) <= kp.cx + kp.hl + w.wide AND greatest(sg.x0, sg.x1) >= kp.cx - kp.hl - w.wide
                           AND least(sg.y0, sg.y1) <= kp.cy + kp.hl + w.wide AND greatest(sg.y0, sg.y1) >= kp.cy - kp.hl - w.wide
                           AND public.rpg_seg_box(e.x0 * kp.rx + e.y0 * kp.ry, e.y0 * kp.rx - e.x0 * kp.ry, e.x1 * kp.rx + e.y1 * kp.ry, e.y1 * kp.rx - e.x1 * kp.ry,
                                                  -(kp.hl + w.wide), -(kp.hw + w.wide), kp.hl + w.wide, kp.hw + w.wide))) AS clear
                 FROM kp GROUP BY kp.j),
             -- the District cells under the corners and middles of the parts of the clear tries
             kq AS MATERIALIZED (
               SELECT kp.j, floor((q.a * kp.hl * kp.rx - q.b * kp.hw * kp.ry + kp.cx) / g.dc)::integer AS dx,
                      floor((q.a * kp.hl * kp.ry + q.b * kp.hw * kp.rx + kp.cy) / g.dc)::integer AS dy
                 FROM kp JOIN kl ON kl.j = kp.j AND kl.clear
                CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             kb AS (SELECT min(kq.dx) AS x0, min(kq.dy) AS y0, max(kq.dx) - min(kq.dx) + 1 AS cols, max(kq.dy) - min(kq.dy) + 1 AS rows FROM kq HAVING count(*) > 0),
             kw AS MATERIALIZED (SELECT f.x, f.y FROM kb CROSS JOIN LATERAL public.rpg_map_flow(6, kb.x0, kb.y0, kb.cols, kb.rows) f WHERE f.depth > 0 OR f.line > 0),
             kd AS (SELECT kl.j FROM kl WHERE kl.clear AND NOT EXISTS (SELECT 1 FROM kq JOIN kw ON kw.x = kq.dx AND kw.y = kq.dy WHERE kq.j = kl.j))
        SELECT jsonb_build_object('j', kc.j, 'x', t.mx + kc.d * cos(kc.th), 'y', t.my + kc.d * sin(kc.th), 'reach', kc.reach / g.sq)
          INTO v_close
          FROM kc WHERE kc.j = (SELECT min(kd.j) FROM kd) LIMIT 1;
      END IF;

      -- the streets behind the main road and the lanes across them, as much as the households need
      SELECT 0.5 * sum(power(public.rpg_map_town_edge(2 * pi() * i / 72, t.r, t.shape), 2)) * 2 * pi() / 72 INTO v_area
        FROM generate_series(0, 71) AS i WHERE t.card IS NULL;
      v_area := coalesce(v_area, pi() * t.cw * t.ch);
      v_need := v_people / g.household
                * ((v_j ->> ('map_house_plot_' || t.kind || '_low'))::double precision + (v_j ->> ('map_house_plot_' || t.kind || '_high'))::double precision) / 2
                * g.perch / g.sq / 2
                - v_len - v_mlen;
      IF v_need > 0 THEN
        v_c := (v_j ->> 'map_street_cross_low')::double precision
               + ((v_j ->> 'map_street_cross_high')::double precision - (v_j ->> 'map_street_cross_low')::double precision)
                 * (public.rpg_map_roll(g.seed, 1283, round(t.mx)::integer, round(t.my)::integer) - 1) / 99.0;
        v_gap := least(greatest(v_area * (1 + 1 / v_c) / v_need, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                       (v_j ->> 'map_street_gap_high')::double precision / g.sq);
        v_reach := greatest(t.fx, t.fy);
        -- where the streets lie each side of the main road, and the lanes each side of the middle
        v_k := 2 * (v_gap - (v_j ->> 'map_street_gap_low')::double precision / g.sq) / v_reach;
        v_offs := '{}'; v_o := 0;
        LOOP
          v_o := v_o + least(greatest((v_j ->> 'map_street_gap_low')::double precision / g.sq + v_k * v_o, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                             (v_j ->> 'map_street_gap_high')::double precision / g.sq);
          EXIT WHEN v_o > v_reach;
          v_offs := v_offs || v_o;
        END LOOP;
        v_coffs := '{}'; v_o := 0;
        LOOP
          v_o := v_o + v_c * least(greatest((v_j ->> 'map_street_gap_low')::double precision / g.sq + v_k * v_o / v_c, (v_j ->> 'map_street_gap_low')::double precision / g.sq),
                                   (v_j ->> 'map_street_gap_high')::double precision / g.sq) / CASE WHEN cardinality(v_coffs) = 0 THEN 2 ELSE 1 END;
          EXIT WHEN v_o > v_reach;
          v_coffs := v_coffs || v_o;
        END LOOP;
        -- each street (o = how far to one side of the main road, along it) and lane (across it, its own way), sampled
        -- every two squares along its length: on the ground (a hair inside its edge) and outside the cathedral close;
        -- each unbroken run of such samples a piece, at least map_street_min_m long
        WITH ln AS (
               SELECT 5 AS class, d.s * n AS o, v_px + (-v_uy) * d.s * v_offs[n] AS bx, v_py + v_ux * d.s * v_offs[n] AS by, v_ux AS ux, v_uy AS uy, 'p' || d.s * n AS tag
                 FROM generate_series(1, cardinality(v_offs)) AS n CROSS JOIN (VALUES (1), (-1)) AS d(s)
               UNION ALL
               SELECT 6, d.s * n, v_px + v_ux * d.s * v_coffs[n], v_py + v_uy * d.s * v_coffs[n], -v_uy, v_ux, 'c' || d.s * n
                 FROM generate_series(1, cardinality(v_coffs)) AS n CROSS JOIN (VALUES (1), (-1)) AS d(s)),
             sm AS (
               SELECT ln.*, s, ln.bx + ln.ux * s AS x, ln.by + ln.uy * s AS y
                 FROM ln CROSS JOIN LATERAL generate_series(-ceil(v_reach / 2)::integer * 2, ceil(v_reach / 2)::integer * 2, 2) AS s),
             si AS (
               SELECT sm.*,
                      CASE WHEN t.card IS NULL
                           THEN sqrt(power(sm.x - t.mx, 2) + power(sm.y - t.my, 2))
                                <= public.rpg_map_town_edge(atan2(sm.y - t.my, sm.x - t.mx), t.r, t.shape) - (v_j ->> 'map_street_edge_m')::double precision / g.sq
                           ELSE power((sm.x - t.mx) / t.cw, 2) + power((sm.y - t.my) / t.ch, 2) <= 1 END
                      AND (v_close IS NULL
                           OR sqrt(power(sm.x - (v_close ->> 'x')::double precision, 2) + power(sm.y - (v_close ->> 'y')::double precision, 2))
                              > (v_close ->> 'reach')::double precision + (v_j ->> 'map_street_close_m')::double precision / g.sq
                                + CASE WHEN sm.class = 6 THEN g.wander6 * v_reach ELSE 0 END + 2) AS ok
                 FROM sm),
             rn AS (SELECT si.*, si.s / 2 - row_number() OVER (PARTITION BY si.class, si.o ORDER BY si.s) AS run FROM si WHERE si.ok),
             pc AS (SELECT rn.class, rn.o, rn.tag, rn.run, rn.ux, rn.uy, min(rn.s) AS s0, max(rn.s) AS s1
                      FROM rn GROUP BY rn.class, rn.o, rn.tag, rn.run, rn.ux, rn.uy
                     HAVING max(rn.s) - min(rn.s) >= (v_j ->> 'map_street_min_m')::double precision / g.sq),
             pe AS (SELECT pc.*, l.bx + l.ux * pc.s0 AS ax, l.by + l.uy * pc.s0 AS ay, l.bx + l.ux * pc.s1 AS ex, l.by + l.uy * pc.s1 AS ey,
                           row_number() OVER (ORDER BY pc.class, abs(pc.o), pc.o, pc.s0) AS i
                      FROM pc JOIN ln l ON l.class = pc.class AND l.o = pc.o)
        SELECT coalesce(jsonb_agg(jsonb_build_object('k', 100 + pe.i, 'class', pe.class, 'ax', pe.ax, 'ay', pe.ay, 'bx', pe.ex, 'by', pe.ey,
                                                     'a', t.town || ':' || pe.tag || ':' || pe.run || ':a', 'b', t.town || ':' || pe.tag || ':' || pe.run || ':b',
                                                     'half', CASE pe.class WHEN 5 THEN g.w5 ELSE g.w6 END / 2) ORDER BY pe.i), '[]'::jsonb)
          INTO v_grid
          FROM pe;
        v_extra := v_extra || v_grid;
      END IF;

      -- the points of the market place, the streets and the lanes, as the roads have theirs (rpg_map_road_lines, 24 points
      -- to the finest bend), where each passes nearest the middle, and its plots from end to end
      WITH ex AS (SELECT (l ->> 'k')::integer AS k, (l ->> 'class')::integer AS class, (l ->> 'ax')::double precision AS ax, (l ->> 'ay')::double precision AS ay,
                         (l ->> 'bx')::double precision AS bx, (l ->> 'by')::double precision AS by, l ->> 'a' AS a, l ->> 'b' AS b,
                         (l ->> 'half')::double precision AS half, o
                    FROM jsonb_array_elements(v_extra) WITH ORDINALITY AS e(l, o)),
           ea AS (SELECT array_agg(ex.class ORDER BY ex.o) AS class, array_agg(ex.ax ORDER BY ex.o) AS ax, array_agg(ex.ay ORDER BY ex.o) AS ay,
                         array_agg(ex.bx ORDER BY ex.o) AS bx, array_agg(ex.by ORDER BY ex.o) AS by, array_agg(ex.a ORDER BY ex.o) AS a, array_agg(ex.b ORDER BY ex.o) AS b
                    FROM ex),
           ep AS MATERIALIZED (SELECT p.i, p.n, p.s, p.x, p.y FROM ea CROSS JOIN LATERAL public.rpg_map_road_lines(ea.class, ea.ax, ea.ay, ea.bx, ea.by, ea.a, ea.b, 1, NULL, NULL, NULL, NULL, NULL, 24) p)
      SELECT v_roads || coalesce(jsonb_agg(jsonb_build_object('k', ex.k, 'class', ex.class, 'ax', ex.ax, 'ay', ex.ay, 'bx', ex.bx, 'by', ex.by,
                                                              'a', ex.a, 'b', ex.b, 'len', l0.len,
                                                              't0', (SELECT ep.s FROM ep WHERE ep.i = ex.o ORDER BY power(ep.x - t.mx, 2) + power(ep.y - t.my, 2) LIMIT 1),
                                                              'half', ex.half, 'lo', 0, 'hi', l0.len,
                                                              'pts', (SELECT jsonb_agg(jsonb_build_array(ep.n, round(ep.s::numeric, 2), round(ep.x::numeric, 2), round(ep.y::numeric, 2)) ORDER BY ep.n)
                                                                        FROM ep WHERE ep.i = ex.o)) ORDER BY ex.o), '[]'::jsonb),
             coalesce(sum(l0.len), 0)
        INTO v_lines, v_mlen
        FROM ex CROSS JOIN LATERAL (SELECT sqrt(power(ex.bx - ex.ax, 2) + power(ex.by - ex.ay, 2)) AS len) l0
       WHERE l0.len > 0;
      -- the market place, streets and lanes lie on the ground end to end: all their length counts
      v_len := v_len + v_mlen;
    END IF;

    -- the plot width, in squares: both sides of the streets shared out among the households, inside its kind's range
    v_new := jsonb_build_object(
      'f', CASE WHEN jsonb_array_length(v_lines) > 0 THEN
             least(greatest(2 * v_len * g.sq / nullif(v_people / g.household, 0),
                            (v_j ->> ('map_house_plot_' || t.kind || '_low'))::double precision * g.perch),
                   (v_j ->> ('map_house_plot_' || t.kind || '_high'))::double precision * g.perch) / g.sq END,
      'people', v_people, 'main', v_main, 'close', v_close, 'lines', v_lines);
    v_new := v_new || jsonb_build_object('plots', 2 * v_len / nullif((v_new ->> 'f')::double precision, 0));
    v_out := v_out || jsonb_build_object(t.town, v_new);
  END LOOP;
  v_tl := v_tl || v_out;
  PERFORM set_config('rpg.townstreets', v_tl::text, true);
  RETURN (SELECT coalesce(jsonb_object_agg(e ->> 'town', v_tl -> (e ->> 'town')), '{}') FROM jsonb_array_elements(p_tw) e);
END;
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
-- middles of the settlements, so a change to either moves them too. Only the battle grid has them; a coarser grid shows the
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
-- lane still has a street through it. A road wanders (step 10b, rpg_map_road_lines): the plots are counted along the
-- straight line between the ends of its stretch, and each stands where the road truly runs at that count, square to
-- the road there; past either end the street runs on straight.
-- Each plot rolls its own house (part 12, layers 1211 to 1219 for the left side, 1221 to 1229 for the right, at the
-- square in the middle of the plot on the road's line):
--   village: a cottage or longhouse 4 to 5.5 m wide (map_house_span_low, _high) and 2 to 4 bays long, a bay 4.6 m
--     (map_house_bay_m; the 15-foot bay of timber framing), one storey under thatch pitched 45 to 55 degrees
--     (map_house_thatch_low, _high), set back 0 to 4 m from the lane (map_house_setback_high); it stands long side to
--     the lane when its plot leaves map_house_gap_m (2 m) to spare, else gable end to the lane, and anywhere along its
--     plot (Dyer 1986 and Gardiner 2014 on peasant houses);
--   town: fills its plot's width less a passage (map_house_passage_m, 1 m) on half the plots, 2 to 3 bays deep,
--     two storeys, on the street line, under clay tiles pitched 40 to 50 degrees (map_house_tile_low, _high);
--   city: the same with two or three storeys; great city (step 12a): three or four.
-- Storeys and their height come from map_house_storeys_<kind>_low, _high and map_house_storey_low, _high (2.4 to 2.9 m
-- a storey, to the eaves). The ridge runs along the longer side.
-- A house stands only when the whole of it lies on its settlement's own ground (its corners and the middles of its
-- sides: rpg_map_town_edge, or the card's own edge, rpg_map_within), clear of every road and street (half its width
-- from its line), clear of the houses of a bigger road, of the road counted first and of the plots nearer the middle,
-- on dry land (no sea under it, rpg_map_heights) and with no river or lake under it, corners, sides or middle (rpg_map_flow).
-- Returns the houses that reach into the block: id (h<road>-<x>-<y><side>), the settlement, its kind, roof (thatch or
-- tile), its middle (cx, cy, world squares counted the way the block counts), the way its ridge runs (ux, uy), half its
-- length and width in squares, the height to its eaves in metres, its roof's pitch in degrees and its storeys.
-- One read of the map asks for the same ground more than once (a block's costs, then its picture; a fight board, then
-- the climb onto one square), so what is worked out is kept in settings of the transaction and gone when it ends: each
-- settlement's streets and plot width (rpg.townstreets, by settlement, kept by rpg_map_town_streets: step 3 its roads, market
-- place, streets and lanes), whether each house stands on its own dry
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
  v_j jsonb;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.houses', true), ''), '{}')::jsonb;
  v_c := v_all -> v_key;
  IF v_c IS NULL THEN
    -- the numbers, read once; r = how far a house reaches from its middle at most, in squares (half the diagonal of
    -- the biggest house, and one more)
    v_j := (SELECT jsonb_object_agg(s.key, s.value) FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key LIKE 'map\_house\_%');
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
                  max(st.v) FILTER (WHERE st.key IN ('map_house_plot_town_high', 'map_house_plot_city_high', 'map_house_plot_great_city_high')) AS plot_hi,
                  max(st.v) FILTER (WHERE st.key = 'map_road_1_width') AS w1, max(st.v) FILTER (WHERE st.key = 'map_road_2_width') AS w2,
                  max(st.v) FILTER (WHERE st.key = 'map_road_3_width') AS w3,
                  (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1)::double precision AS world
             FROM st)
    SELECT cfg.*, ceil(greatest(sqrt(power(cfg.vbays_hi * cfg.bay, 2) + power(cfg.span_hi, 2)),
                                sqrt(power(cfg.tbays_hi * cfg.bay, 2) + power(cfg.plot_hi * cfg.perch, 2)),
                                sqrt(power(2 * cfg.plot_hi * cfg.perch, 2) + power(1.5 * cfg.bay, 2)),
                                sqrt(power(x.barn_bays_hi * cfg.bay, 2) + power(x.barn_span_hi, 2)),
                                sqrt(power(x.wing_bays_hi * cfg.bay + 0.5, 2) + power(x.wing_wide_hi, 2))) / 2 / cfg.sq) + 1 AS r,
           -- how far back from the street's edge a house's farthest part may lie (a village barn behind its house, a town
           -- house's back range), in metres; the same for a church (its churchyard and its whole length), and how far a
           -- part of a church may reach from its middle, in squares (step 14e)
           greatest(cfg.setback_hi + cfg.vbays_hi * cfg.bay + x.barn_gap_hi + x.barn_bays_hi * cfg.bay,
                    cfg.tbays_hi * cfg.bay + x.wing_bays_hi * cfg.bay + 0.5) AS deep,
           x.church_setback_hi + x.church_tower_hi + x.church_nave_len_hi + x.church_chancel_hi AS cdeep,
           ceil(sqrt(power(x.church_nave_len_hi, 2) + power(greatest(x.church_aisled_hi, x.church_nave_wide_hi), 2)) / 2 / cfg.sq) + 1 AS rc,
           (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = 6)::double precision AS dc
      INTO g
      FROM cfg
     CROSS JOIN LATERAL (
       SELECT (v_j ->> 'map_house_barn_bays_high')::double precision AS barn_bays_hi, (v_j ->> 'map_house_barn_span_high')::double precision AS barn_span_hi,
              (v_j ->> 'map_house_barn_gap_high')::double precision AS barn_gap_hi, (v_j ->> 'map_house_wing_bays_high')::double precision AS wing_bays_hi,
              (v_j ->> 'map_house_wing_wide_high')::double precision AS wing_wide_hi, (v_j ->> 'map_house_church_setback_high')::double precision AS church_setback_hi,
              (v_j ->> 'map_house_church_tower_side_high')::double precision AS church_tower_hi, (v_j ->> 'map_house_church_nave_len_high')::double precision AS church_nave_len_hi,
              (v_j ->> 'map_house_church_chancel_len_high')::double precision AS church_chancel_hi, (v_j ->> 'map_house_church_aisled_wide_high')::double precision AS church_aisled_hi,
              (v_j ->> 'map_house_church_nave_wide_high')::double precision AS church_nave_wide_hi) x;

    -- the villages, towns and cities whose ground reaches the box of the houses that might overlap those reaching the
    -- block (three reaches round it; rpg_map_town_grounds), and their streets and plot widths (rpg_map_town_streets,
    -- step 3: the roads, the market place, the streets and lanes inside a town or city, a great city's cathedral close)
    v_tw := public.rpg_map_town_grounds(p_x0 - 3 * g.r, p_y0 - 3 * g.r, p_x0 + p_cols + 3 * g.r, p_y0 + p_rows + 3 * g.r);

    IF jsonb_array_length(v_tw) = 0 THEN
      v_c := '[]'::jsonb;
    ELSE
      v_tl := public.rpg_map_town_streets(v_tw);

      -- the plots near the block and the building each holds (step 14e, Peter 2026-10-07 21:05: cities need more building
      -- variety). Every plot rolls what stands on it from its own rolls (u1 to u9 as before, v1 to v12 from part 12,
      -- layers 1241 to 1252 for the left side, 1261 to 1272 for the right), so each block of the map gets the same
      -- answer for the same plot. What the plot holds (use):
      --   the main plot of a settlement (its first road, the plot just past where that road passes nearest the middle,
      --     left side) holds its main church: always in a town or city, in a village when v1 < map_house_church_village_share
      --     (about half of medieval villages had their own church; the rest shared a parish); a great city's cathedral
      --     stands in its own close (below);
      --   any other plot of a town, city or great city holds a parish church when v1 < (churches - 1) / plots, churches
      --     being its people over map_house_church_people_<kind> (one church to 1,200 people in a town, 600 in a city or
      --     great city: York had about 40 parishes for 10,000 to 15,000 people, Norwich 46 for 25,000, Bristol 18 for
      --     10,000; Rosser 1988, Palliser 2000) and plots both sides of its streets over the plot width;
      --   every other plot a house, as before. In a town, city or great city it is a hall house set along the street
      --     across two plots (Pantin 1962's parallel plan) when v2 < map_house_hall_share, and has a back range (a wing
      --     running back from one side of the front range, Pantin's right-angle plan) when v3 < map_house_wing_share;
      --     in a village a barn stands behind the house when v3 < map_house_barn_share (Wharram Percy and other
      --     excavated tofts: a house and a barn or byre; Dyer 1986, Wrathmell 2012).
      -- Roofs: each house rolls its roof from v4 against map_house_roof_<kind>_thatch and _slate (the rest clay tile):
      -- thatch in nine villages in ten and still in some towns, stone slate where the stone splits, tile in the towns
      -- and cities. Stone slate pitches map_house_slate_low to _high degrees.
      -- A church: a nave (map_house_church_nave_*), a chancel to its east (map_house_church_chancel_*) and a tower at its
      -- west end (map_house_church_tower_*), the whole laid east to west as medieval churches were, set back from the
      -- street by its churchyard (map_house_church_setback_*); a village church has an aisleless nave, a town or city
      -- church an aisled one (map_house_church_aisled_*). Its nave and chancel roof is lead at a low pitch, stone slate
      -- or tile; its tower has a spire (v11 < map_house_church_spire_share, pitch map_house_church_spire_pitch) or a flat
      -- leaded top inside a parapet. A cathedral: a nave with aisles, transepts across it, a choir to the east, a tower
      -- over the crossing and two west towers (map_house_cathedral_*; Salisbury, Wells, Lincoln and Exeter run about 100
      -- to 140 m end to end), under steep lead roofs.
      -- Churches and the cathedral come first, so houses give way to them; a building's own parts never block each
      -- other; a building stands only if every part of it does. Each part is a row: the id of a building is its first
      -- part's id, h (house), b (barn), c (church) or k (cathedral) then the road, the plot's square and side, and every
      -- other part adds a dot and a letter: .w a house's back range, .n nave, .c chancel, .t tower, .x transepts, .q
      -- choir, .a and .b the west towers.
      WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                             shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                             fx double precision, fy double precision)),
           lr AS MATERIALIZED (
             SELECT tw.town, tw.kind, (v_tl -> tw.town ->> 'f')::double precision AS f,
                    coalesce((v_tl -> tw.town ->> 'plots')::double precision, 0) AS plots, coalesce((v_tl -> tw.town ->> 'people')::double precision, 0) AS people,
                    (v_tl -> tw.town ->> 'main')::integer AS main, l.*
               FROM tw CROSS JOIN LATERAL jsonb_to_recordset(v_tl -> tw.town -> 'lines')
                       AS l(k integer, class integer, ax double precision, ay double precision, bx double precision, by double precision, a text, b text,
                            len double precision, t0 double precision, half double precision, lo double precision, hi double precision, pts jsonb)),
           -- the pieces of every line: from one point to the next, and straight on past an end where the street runs on
           sg AS MATERIALIZED (
             SELECT q.town, q.k, q.x0, q.y0, q.x1, q.y1
               FROM (SELECT lr.town, lr.k, p.x, p.y, p.n, lead(p.x) OVER w AS x1, lead(p.y) OVER w AS y1, lead(p.n) OVER w AS n1
                       FROM lr CROSS JOIN LATERAL jsonb_array_elements(lr.pts) AS e(v)
                      CROSS JOIN LATERAL (SELECT (e.v ->> 0)::integer AS n, (e.v ->> 2)::double precision AS x, (e.v ->> 3)::double precision AS y) p
                     WINDOW w AS (PARTITION BY lr.town, lr.k ORDER BY p.n)) q(town, k, x0, y0, n, x1, y1, n1)
              WHERE q.n1 = q.n + 1
             UNION ALL
             SELECT lr.town, lr.k, lr.ax + d.ux * lr.lo, lr.ay + d.uy * lr.lo, lr.ax, lr.ay
               FROM lr CROSS JOIN LATERAL (SELECT (lr.bx - lr.ax) / lr.len AS ux, (lr.by - lr.ay) / lr.len AS uy) d WHERE lr.lo < 0
             UNION ALL
             SELECT lr.town, lr.k, lr.bx, lr.by, lr.ax + d.ux * lr.hi, lr.ay + d.uy * lr.hi
               FROM lr CROSS JOIN LATERAL (SELECT (lr.bx - lr.ax) / lr.len AS ux, (lr.by - lr.ay) / lr.len AS uy) d WHERE lr.hi > lr.len),
           -- how far along each line the plots near the box may lie: where its points and its straight ends come within a
           -- street, the deepest a building may stand back from it and three reaches of a part of the box (houses: g.r;
           -- churches: g.rc, a bigger reach, so a parish church's plot is looked at from further off)
           pr AS MATERIALIZED (
             SELECT lr.*, q.tmin - lr.f AS tmin, q.tmax + lr.f AS tmax, q.cmin - lr.f AS cmin, q.cmax + lr.f AS cmax
               FROM lr
              CROSS JOIN LATERAL (SELECT lr.half + g.deep / g.sq + g.r AS reach, lr.half + g.cdeep / g.sq + g.rc AS creach) e
              CROSS JOIN LATERAL (
                SELECT min(u.s) FILTER (WHERE u.near) AS tmin, max(u.s) FILTER (WHERE u.near) AS tmax, min(u.s) AS cmin, max(u.s) AS cmax
                  FROM (SELECT (pe.v ->> 1)::double precision AS s,
                               (pe.v ->> 2)::double precision BETWEEN p_x0 - 3 * g.r - e.reach AND p_x0 + p_cols + 3 * g.r + e.reach
                               AND (pe.v ->> 3)::double precision BETWEEN p_y0 - 3 * g.r - e.reach AND p_y0 + p_rows + 3 * g.r + e.reach AS near
                          FROM jsonb_array_elements(lr.pts) AS pe(v)
                         WHERE (pe.v ->> 2)::double precision BETWEEN p_x0 - 3 * g.rc - e.creach AND p_x0 + p_cols + 3 * g.rc + e.creach
                           AND (pe.v ->> 3)::double precision BETWEEN p_y0 - 3 * g.rc - e.creach AND p_y0 + p_rows + 3 * g.rc + e.creach
                        UNION ALL
                        SELECT v.s, public.rpg_seg_box(lr.ax + (lr.bx - lr.ax) / lr.len * lr.lo, lr.ay + (lr.by - lr.ay) / lr.len * lr.lo, lr.ax, lr.ay,
                                                       p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)
                          FROM (VALUES (lr.lo), (0::double precision)) AS v(s)
                         WHERE lr.lo < 0 AND public.rpg_seg_box(lr.ax + (lr.bx - lr.ax) / lr.len * lr.lo, lr.ay + (lr.by - lr.ay) / lr.len * lr.lo, lr.ax, lr.ay,
                                                                p_x0 - 3 * g.rc - e.creach, p_y0 - 3 * g.rc - e.creach, p_x0 + p_cols + 3 * g.rc + e.creach, p_y0 + p_rows + 3 * g.rc + e.creach)
                        UNION ALL
                        SELECT v.s, public.rpg_seg_box(lr.bx, lr.by, lr.ax + (lr.bx - lr.ax) / lr.len * lr.hi, lr.ay + (lr.by - lr.ay) / lr.len * lr.hi,
                                                       p_x0 - 3 * g.r - e.reach, p_y0 - 3 * g.r - e.reach, p_x0 + p_cols + 3 * g.r + e.reach, p_y0 + p_rows + 3 * g.r + e.reach)
                          FROM (VALUES (lr.len), (lr.hi)) AS v(s)
                         WHERE lr.hi > lr.len AND public.rpg_seg_box(lr.bx, lr.by, lr.ax + (lr.bx - lr.ax) / lr.len * lr.hi, lr.ay + (lr.by - lr.ay) / lr.len * lr.hi,
                                                                     p_x0 - 3 * g.rc - e.creach, p_y0 - 3 * g.rc - e.creach, p_x0 + p_cols + 3 * g.rc + e.creach, p_y0 + p_rows + 3 * g.rc + e.creach)) u) q
              WHERE lr.f > 0 AND q.cmin IS NOT NULL),
           -- the plots: near = within the houses' reach of the box; the rest are looked at only as churches. The main plot
           -- of every settlement whose first road comes near is always looked at, wherever it lies, so its main church or
           -- cathedral is found from every block it reaches.
           pl0 AS (
             SELECT pr.town, pr.kind, pr.k, pr.class, pr.half, pr.f, pr.plots, pr.people, pr.main, j, s.side,
                    pr.t0 + (j + 0.5) * pr.f AS tm, pr.t0 + (j + 0.5) * pr.f < 0 OR pr.t0 + (j + 0.5) * pr.f > pr.len AS cont,
                    pr.tmin IS NOT NULL AND pr.t0 + (j + 0.5) * pr.f BETWEEN pr.tmin - pr.f AND pr.tmax + pr.f AS near
               FROM pr
              CROSS JOIN LATERAL generate_series(greatest(ceil((pr.lo - pr.t0) / pr.f - 1e-6), floor((pr.cmin - pr.t0) / pr.f) - 1)::integer,
                                                 least(floor((pr.hi - pr.t0) / pr.f + 1e-6) - 1, ceil((pr.cmax - pr.t0) / pr.f) + 1)::integer) AS j
              CROSS JOIN (VALUES (-1), (1)) AS s(side)
             UNION
             SELECT lr.town, lr.kind, lr.k, lr.class, lr.half, lr.f, lr.plots, lr.people, lr.main, 0, -1, lr.t0 + 0.5 * lr.f,
                    lr.t0 + 0.5 * lr.f < 0 OR lr.t0 + 0.5 * lr.f > lr.len, false
               FROM lr WHERE lr.k = lr.main AND lr.f > 0 AND lr.t0 + 0.5 * lr.f BETWEEN lr.lo AND lr.hi),
           pl AS MATERIALIZED (SELECT pl0.town, pl0.kind, pl0.k, pl0.class, pl0.half, pl0.f, pl0.plots, pl0.people, pl0.j, pl0.side, pl0.tm, pl0.cont,
                                      bool_or(pl0.near) AS near, pl0.k = pl0.main AND pl0.j = 0 AND pl0.side = -1 AS main
                                 FROM pl0 GROUP BY pl0.town, pl0.kind, pl0.k, pl0.class, pl0.half, pl0.f, pl0.plots, pl0.people, pl0.j, pl0.side, pl0.tm, pl0.cont, pl0.main),
           -- where the road runs at the middle of each plot (rpg_map_road_line at that count along the line), and the
           -- way it runs there: along it (ux, uy) and across it (nx, ny)
           pq AS (SELECT pl.town, pl.k, array_agg(DISTINCT pl.tm ORDER BY pl.tm) AS tms FROM pl GROUP BY pl.town, pl.k),
           pp AS MATERIALIZED (
             SELECT pq.town, pq.k, pq.tms[p.n] AS tm, p.x, p.y, p.ux, p.uy, -p.uy AS nx, p.ux AS ny
               FROM pq JOIN pr ON pr.town = pq.town AND pr.k = pq.k
              CROSS JOIN LATERAL public.rpg_map_road_line(pr.class, pr.ax, pr.ay, pr.bx, pr.by, pr.a, pr.b, 1, pq.tms) p),
           -- each plot's own rolls (u1 to u9 and v1 to v12, 0 to 1) at the square in its middle on the road's line, and
           -- what it holds
           pu AS MATERIALIZED (
             SELECT pl.*, pp.x AS lx, pp.y AS ly, pp.ux, pp.uy, pp.nx, pp.ny, round(pp.x)::integer AS px, round(pp.y)::integer AS py,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + CASE WHEN pl.side > 0 THEN 10 ELSE 0 END + n,
                                                           round(pp.x)::integer, round(pp.y)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + CASE WHEN pl.side > 0 THEN 20 ELSE 0 END + n,
                                                           round(pp.x)::integer, round(pp.y)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 12) AS n) AS v
               FROM pl JOIN pp ON pp.town = pl.town AND pp.k = pl.k AND pp.tm = pl.tm),
           pk AS MATERIALIZED (
             SELECT pu.*, w.use
               FROM pu
              CROSS JOIN LATERAL (
                SELECT CASE WHEN pu.main AND pu.kind <> 'village' THEN 'church'
                            WHEN pu.main AND pu.v[1] < (v_j ->> 'map_house_church_village_share')::double precision THEN 'church'
                            WHEN pu.kind <> 'village' AND pu.plots > 0
                             AND pu.v[1] < (greatest(pu.people / nullif((v_j ->> ('map_house_church_people_' || pu.kind))::double precision, 0), 1) - 1) / pu.plots THEN 'church'
                            ELSE 'house' END AS use) w
              WHERE pu.near OR w.use <> 'house'),
           -- a great city's cathedral stands in its own close (rpg_map_town_streets, step 3: the try found there, the
           -- nearest clear of the roads and the market place with no water under it; the streets and lanes keep out of
           -- it); its sizes come from the rolls at the middle square (part 12, layers 1241 to 1252 and 1211 to 1219)
           kc AS (
             SELECT tw.town, tw.kind, round(tw.mx)::integer AS px, round(tw.my)::integer AS py, (v_tl -> tw.town -> 'close' ->> 'j')::integer AS n,
                    (v_tl -> tw.town -> 'close' ->> 'x')::double precision AS lx, (v_tl -> tw.town -> 'close' ->> 'y')::double precision AS ly,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1210 + n, round(tw.mx)::integer, round(tw.my)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 9) AS n) AS u,
                    (SELECT array_agg((public.rpg_map_roll(g.seed, 1240 + n, round(tw.mx)::integer, round(tw.my)::integer) - 1) / 99.0 ORDER BY n)
                       FROM generate_series(1, 12) AS n) AS v
               FROM tw
              WHERE tw.kind = 'great_city' AND jsonb_typeof(v_tl -> tw.town -> 'close') = 'object'),
           -- a house, in metres (as before; a hall house fills two plots along the street, one bay deep and a half more)
           hm AS (
             SELECT pk.*, d.*
               FROM pk
              CROSS JOIN LATERAL (
                SELECT (v_j ->> ('map_house_storeys_' || pk.kind || '_low'))::double precision AS s_lo,
                       (v_j ->> ('map_house_storeys_' || pk.kind || '_high'))::double precision AS s_hi,
                       (v_j ->> ('map_house_roof_' || pk.kind || '_thatch'))::double precision AS r_th,
                       (v_j ->> ('map_house_roof_' || pk.kind || '_slate'))::double precision AS r_sl) k
              CROSS JOIN LATERAL (
                SELECT CASE WHEN pk.v[4] < k.r_th THEN 'thatch' WHEN pk.v[4] < k.r_th + k.r_sl THEN 'slate' ELSE 'tile' END AS roof) m
              CROSS JOIN LATERAL (
                SELECT (k.s_lo + least(floor((k.s_hi - k.s_lo + 1) * pk.u[3]), k.s_hi - k.s_lo))::integer AS storeys,
                       g.span_lo + (g.span_hi - g.span_lo) * pk.u[1] AS span,
                       CASE WHEN pk.kind = 'village' THEN g.vbays_lo + least(floor((g.vbays_hi - g.vbays_lo + 1) * pk.u[2]), g.vbays_hi - g.vbays_lo)
                            ELSE g.tbays_lo + least(floor((g.tbays_hi - g.tbays_lo + 1) * pk.u[2]), g.tbays_hi - g.tbays_lo) END * g.bay AS length,
                       g.storey_lo + (g.storey_hi - g.storey_lo) * pk.u[4] AS storey,
                       m.roof,
                       CASE m.roof WHEN 'thatch' THEN g.thatch_lo + (g.thatch_hi - g.thatch_lo) * pk.u[5]
                                   WHEN 'slate' THEN (v_j ->> 'map_house_slate_low')::double precision
                                                     + ((v_j ->> 'map_house_slate_high')::double precision - (v_j ->> 'map_house_slate_low')::double precision) * pk.u[5]
                                   ELSE g.tile_lo + (g.tile_hi - g.tile_lo) * pk.u[5] END AS pitch,
                       CASE WHEN pk.kind = 'village' THEN g.setback_hi * pk.u[6] ELSE 0 END AS setback,
                       CASE WHEN pk.kind <> 'village' AND pk.u[7] < 0.5 THEN g.passage ELSE 0 END AS passage,
                       pk.kind <> 'village' AND pk.v[2] < (v_j ->> 'map_house_hall_share')::double precision AS hall) d
              WHERE pk.use = 'house'),
           -- along = along the road, deep = back from it; a village house long side to the lane when its toft leaves
           -- map_house_gap_m beside it, else gable end on; a town or city house fills its plot less any passage; a hall
           -- house runs along two plots, toward the end of the street, a bay and a half deep
           hs AS (
             SELECT hm.*, a.along, a.deep,
                    CASE WHEN hm.kind = 'village' THEN (hm.f * g.sq - a.along) * (hm.u[7] - 0.5)
                         WHEN hm.hall THEN CASE WHEN hm.j >= 0 THEN 1 ELSE -1 END * hm.f * g.sq / 2
                         WHEN hm.u[8] < 0.5 THEN -hm.passage / 2 ELSE hm.passage / 2 END AS off
               FROM hm
              CROSS JOIN LATERAL (
                SELECT CASE WHEN hm.hall THEN 2 * hm.f * g.sq - hm.passage
                            WHEN hm.kind <> 'village' THEN hm.f * g.sq - hm.passage
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.length ELSE hm.span END AS along,
                       CASE WHEN hm.hall THEN 1.5 * g.bay
                            WHEN hm.kind <> 'village' THEN hm.length
                            WHEN hm.length + g.gap <= hm.f * g.sq THEN hm.span ELSE hm.length END AS deep) a),
           -- the parts of every building, in metres from the plot's point on the road: a (along the road) and b (back from
           -- the street's edge) to its middle, the way its ridge runs (east = the compass for a church, else along or
           -- across the road), its length and width, its eaves, pitch, storeys and roof
           pa AS (
             -- the house itself
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'h' AS pre, '' AS suf, 2 AS rank, 0 AS o, hs.off AS a, hs.setback + hs.deep / 2 AS b, 'road' AS way,
                    greatest(hs.along, hs.deep) AS len, least(hs.along, hs.deep) AS wide, hs.along >= hs.deep AS along_ridge,
                    hs.storeys * hs.storey AS eaves, hs.pitch, hs.storeys, hs.roof
               FROM hs
             UNION ALL
             -- its back range (a town, city or great city): along one side of the plot, running back from the front
             -- range, map_house_wing_wide_* wide, map_house_wing_bays_* bays long, as many storeys or one fewer
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'h', '.w', 2, 0,
                    hs.off + CASE WHEN hs.v[5] < 0.5 THEN -1 ELSE 1 END * (hs.along - w.wide) / 2,
                    hs.setback + hs.deep + w.long / 2 - 0.5, 'road', w.long + 0.5, w.wide, false,
                    w.storeys * hs.storey, hs.pitch, w.storeys, hs.roof
               FROM hs
              CROSS JOIN LATERAL (
                SELECT least((v_j ->> 'map_house_wing_wide_low')::double precision
                             + ((v_j ->> 'map_house_wing_wide_high')::double precision - (v_j ->> 'map_house_wing_wide_low')::double precision) * hs.v[6],
                             hs.along - 1) AS wide,
                       ((v_j ->> 'map_house_wing_bays_low')::double precision
                        + least(floor(((v_j ->> 'map_house_wing_bays_high')::double precision - (v_j ->> 'map_house_wing_bays_low')::double precision + 1) * hs.v[7]),
                                (v_j ->> 'map_house_wing_bays_high')::double precision - (v_j ->> 'map_house_wing_bays_low')::double precision)) * g.bay AS long,
                       greatest(hs.storeys - CASE WHEN hs.v[8] < 0.5 THEN 1 ELSE 0 END, 1) AS storeys) w
              WHERE hs.kind <> 'village' AND NOT hs.hall AND hs.v[3] < (v_j ->> 'map_house_wing_share')::double precision AND w.wide >= 2
             UNION ALL
             -- a village barn behind the house: map_house_barn_bays_* bays of map_house_bay_m, map_house_barn_span_* wide,
             -- map_house_barn_gap_* behind it, its ridge along or across the toft, one tall storey, thatched
             SELECT hs.town, hs.kind, hs.k, hs.class, hs.cont, hs.j, hs.side, hs.half, hs.lx, hs.ly, hs.ux, hs.uy, hs.nx, hs.ny, hs.px, hs.py,
                    'b', '', 2, 1,
                    (hs.f * g.sq - CASE WHEN w.across THEN w.wide ELSE w.long END) * (hs.v[9] - 0.5),
                    hs.setback + hs.deep + w.gap + CASE WHEN w.across THEN w.long ELSE w.wide END / 2, 'road', w.long, w.wide, NOT w.across,
                    w.eaves, g.thatch_lo + (g.thatch_hi - g.thatch_lo) * hs.v[10], 1, 'thatch'
               FROM hs
              CROSS JOIN LATERAL (
                SELECT ((v_j ->> 'map_house_barn_bays_low')::double precision
                        + least(floor(((v_j ->> 'map_house_barn_bays_high')::double precision - (v_j ->> 'map_house_barn_bays_low')::double precision + 1) * hs.v[6]),
                                (v_j ->> 'map_house_barn_bays_high')::double precision - (v_j ->> 'map_house_barn_bays_low')::double precision)) * g.bay AS long,
                       (v_j ->> 'map_house_barn_span_low')::double precision
                        + ((v_j ->> 'map_house_barn_span_high')::double precision - (v_j ->> 'map_house_barn_span_low')::double precision) * hs.v[7] AS wide,
                       (v_j ->> 'map_house_barn_gap_low')::double precision
                        + ((v_j ->> 'map_house_barn_gap_high')::double precision - (v_j ->> 'map_house_barn_gap_low')::double precision) * hs.v[8] AS gap,
                       (v_j ->> 'map_house_barn_eaves_low')::double precision
                        + ((v_j ->> 'map_house_barn_eaves_high')::double precision - (v_j ->> 'map_house_barn_eaves_low')::double precision) * hs.v[11] AS eaves,
                       hs.v[12] < 0.5 AS across) w
              WHERE hs.kind = 'village' AND hs.v[3] < (v_j ->> 'map_house_barn_share')::double precision
             UNION ALL
             -- a church or the cathedral: its parts laid east to west about the middle of the whole, which stands back
             -- from the street by its churchyard and its own reach across the street
             SELECT pk.town, pk.kind, pk.k, pk.class, pk.cont, pk.j, pk.side, pk.half, pk.lx, pk.ly, pk.ux, pk.uy, pk.nx, pk.ny, pk.px, pk.py,
                    'c', c.suf, 1, c.o,
                    c.ex * pk.ux + c.ey * pk.uy,
                    w.back + (c.ex * pk.nx + c.ey * pk.ny) * pk.side, 'east', c.len, c.wide, c.ridge_ew,
                    c.eaves, c.pitch, 1, c.roof
               FROM pk
              CROSS JOIN LATERAL public.rpg_map_church_plan(pk.use, pk.kind, pk.u::double precision[], pk.v::double precision[], v_j) c
              CROSS JOIN LATERAL (
                SELECT (v_j ->> 'map_house_church_setback_low')::double precision
                       + ((v_j ->> 'map_house_church_setback_high')::double precision - (v_j ->> 'map_house_church_setback_low')::double precision) * pk.u[6]
                       + (SELECT max(abs(z.ex * pk.nx + z.ey * pk.ny)
                                     + abs(CASE WHEN z.ridge_ew THEN z.len ELSE z.wide END / 2 * pk.nx)
                                     + abs(CASE WHEN z.ridge_ew THEN z.wide ELSE z.len END / 2 * pk.ny))
                            FROM public.rpg_map_church_plan(pk.use, pk.kind, pk.u::double precision[], pk.v::double precision[], v_j) z) AS back) w
              WHERE pk.use = 'church'
             UNION ALL
             -- a great city's cathedral in its close (j = the try it stands at): its parts about its middle
             SELECT kc.town, kc.kind, 0, 0, false, kc.n, 1, 0::double precision,
                    kc.lx, kc.ly, 1::double precision, 0::double precision, 0::double precision, 1::double precision,
                    kc.px, kc.py, 'k', c.suf, 0, 0, c.ex, c.ey, 'east', c.len, c.wide, c.ridge_ew, c.eaves, c.pitch, 1, c.roof
               FROM kc CROSS JOIN LATERAL public.rpg_map_church_plan('cathedral', kc.kind, kc.u::double precision[], kc.v::double precision[], v_j) c),
           -- in squares on the map: the middle, the way of the ridge and the half sides
           hc AS MATERIALIZED (
             SELECT pa.town, pa.kind, pa.k, pa.class, pa.cont, pa.j, pa.side, pa.rank, pa.o, pa.pre,
                    pa.pre || CASE WHEN pa.pre = 'k' THEN pa.j::text ELSE pa.k::text END || '-' || pa.px || '-' || pa.py || CASE WHEN pa.side > 0 THEN 'r' ELSE 'l' END AS base,
                    pa.pre || CASE WHEN pa.pre = 'k' THEN pa.j::text ELSE pa.k::text END || '-' || pa.px || '-' || pa.py || CASE WHEN pa.side > 0 THEN 'r' ELSE 'l' END || pa.suf AS id,
                    pa.lx + (pa.ux * pa.a + pa.nx * pa.side * pa.b) / g.sq + pa.nx * pa.side * pa.half AS cx,
                    pa.ly + (pa.uy * pa.a + pa.ny * pa.side * pa.b) / g.sq + pa.ny * pa.side * pa.half AS cy,
                    CASE WHEN pa.way = 'east' THEN CASE WHEN pa.along_ridge THEN 1 ELSE 0 END
                         WHEN pa.along_ridge THEN pa.ux ELSE pa.nx END AS rx,
                    CASE WHEN pa.way = 'east' THEN CASE WHEN pa.along_ridge THEN 0 ELSE 1 END
                         WHEN pa.along_ridge THEN pa.uy ELSE pa.ny END AS ry,
                    pa.len / 2 / g.sq AS hl, pa.wide / 2 / g.sq AS hw,
                    pa.eaves, pa.pitch, pa.storeys, pa.roof
               FROM pa),
           -- the parts in that box that keep clear of every road and street of their settlement (every piece of every
           -- line, half its width from it; step 3: a church keeps clear of the roads and the market place only, and the
           -- streets and lanes inside the town stop at its churchyard, as they went round churchyards; rpg_map_street_cells),
           -- each building with its place in the order: the cathedral, then churches,
           -- then houses and barns; bigger road first, then the road counted first, its own road before the street it runs
           -- on as, then the plot nearer the middle, a house before its barn
           cl AS MATERIALIZED (
             SELECT hc.*, dense_rank() OVER (PARTITION BY hc.town ORDER BY hc.rank, hc.class, hc.k, hc.cont, abs(hc.j), hc.j, hc.side, hc.o) AS n,
                    NOT EXISTS (
                      SELECT 1 FROM sg JOIN lr ON lr.town = sg.town AND lr.k = sg.k
                       CROSS JOIN LATERAL (SELECT lr.half - 0.01 AS wide) w
                       CROSS JOIN LATERAL (SELECT sg.x0 - hc.cx AS x0, sg.y0 - hc.cy AS y0, sg.x1 - hc.cx AS x1, sg.y1 - hc.cy AS y1) e
                       WHERE sg.town = hc.town AND NOT (hc.rank = 1 AND lr.class >= 5)
                         AND least(sg.x0, sg.x1) <= hc.cx + hc.hl + w.wide AND greatest(sg.x0, sg.x1) >= hc.cx - hc.hl - w.wide
                         AND least(sg.y0, sg.y1) <= hc.cy + hc.hl + w.wide AND greatest(sg.y0, sg.y1) >= hc.cy - hc.hl - w.wide
                         AND public.rpg_seg_box(e.x0 * hc.rx + e.y0 * hc.ry, e.y0 * hc.rx - e.x0 * hc.ry, e.x1 * hc.rx + e.y1 * hc.ry, e.y1 * hc.rx - e.x1 * hc.ry,
                                                -(hc.hl + w.wide), -(hc.hw + w.wide), hc.hl + w.wide, hc.hw + w.wide)) AS clear
               FROM hc
              WHERE hc.base IN (SELECT h2.base FROM hc h2
                                 WHERE h2.rank = 0
                                    OR (h2.rank = 1 AND h2.cx BETWEEN p_x0 - 3 * g.rc AND p_x0 + p_cols + 3 * g.rc AND h2.cy BETWEEN p_y0 - 3 * g.rc AND p_y0 + p_rows + 3 * g.rc)
                                    OR (h2.cx BETWEEN p_x0 - 3 * g.r AND p_x0 + p_cols + 3 * g.r AND h2.cy BETWEEN p_y0 - 3 * g.r AND p_y0 + p_rows + 3 * g.r))),
           -- a building clear of every road (all its parts), and of those the parts that meet a part of such a building
           -- before it: a building stands when none of its parts does
           cb0 AS (SELECT cl.base, cl.town, min(cl.rank) AS rank, min(cl.j) AS j FROM cl GROUP BY cl.base, cl.town HAVING bool_and(cl.clear)),
           cb AS (SELECT cb0.base FROM cb0),
           cc AS MATERIALIZED (SELECT cl.* FROM cl WHERE cl.base IN (SELECT cb.base FROM cb)),
           bl AS MATERIALIZED (
             SELECT cc.*,
                    EXISTS (SELECT 1 FROM cc c2
                             WHERE c2.town = cc.town AND c2.n < cc.n
                               AND public.rpg_map_rects_meet(cc.cx, cc.cy, cc.rx, cc.ry, cc.hl, cc.hw, c2.cx, c2.cy, c2.rx, c2.ry, c2.hl, c2.hw)) AS hit
               FROM cc),
           bk AS (SELECT bl.base FROM bl GROUP BY bl.base HAVING NOT bool_or(bl.hit))
      -- of those, the buildings with a part that reaches the block: all their parts
      SELECT coalesce(jsonb_agg(jsonb_build_object('id', bl.id, 'base', bl.base, 'town', bl.town, 'kind', bl.kind, 'roof', bl.roof, 'cx', bl.cx, 'cy', bl.cy,
                                                   'ux', bl.rx, 'uy', bl.ry, 'half_len', bl.hl, 'half_wide', bl.hw, 'eaves', bl.eaves,
                                                   'pitch', bl.pitch, 'storeys', bl.storeys) ORDER BY bl.town, bl.n, bl.id), '[]'::jsonb)
        INTO v_hb
        FROM bl
       WHERE bl.base IN (SELECT bk.base FROM bk)
         AND bl.base IN (SELECT b2.base FROM bl b2
                          WHERE public.rpg_map_rects_meet(b2.cx, b2.cy, b2.rx, b2.ry, b2.hl, b2.hw, p_x0 + p_cols / 2.0, p_y0 + p_rows / 2.0, 1, 0, p_cols / 2.0, p_rows / 2.0));

      -- whether each building stands on its own dry ground, once a transaction: the four corners and the middles of the
      -- four sides of every part, a hair in, and its middle, on its settlement's ground and not the sea, and no river or
      -- lake under any of them. The water is read in two goes (step 14e): first the District grid's cells round the
      -- points (rpg_map_flow at that grid: a river, stream or brook whose line runs through a cell, or water at its
      -- middle), then the battle grid only over the points that lie in or beside such a cell, so a town far from any
      -- water reads none of it square by square; the answer is the same as reading every square.
      v_ok := coalesce(nullif(current_setting('rpg.houseok', true), ''), '{}')::jsonb;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_hb) h WHERE NOT v_ok ? (h ->> 'base')) THEN
        WITH tw AS (SELECT * FROM jsonb_to_recordset(v_tw) AS x(town text, kind text, mx double precision, my double precision, r double precision,
                                                               shape double precision[], card uuid, people integer, cw double precision, ch double precision,
                                                               fx double precision, fy double precision)),
             hb AS (SELECT * FROM jsonb_to_recordset(v_hb) AS h(id text, base text, town text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                                half_len double precision, half_wide double precision)
                     WHERE NOT v_ok ? h.base),
             pt AS MATERIALIZED (
               SELECT hb.base, hb.town, q.a * (hb.half_len - 0.01) * hb.ux - q.b * (hb.half_wide - 0.01) * hb.uy + hb.cx AS x,
                      q.a * (hb.half_len - 0.01) * hb.uy + q.b * (hb.half_wide - 0.01) * hb.ux + hb.cy AS y
                 FROM hb CROSS JOIN (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS q(a, b)),
             -- the land and sea under them, and a card's own edge, read once as a block
             ab AS (SELECT floor(min(pt.x))::integer AS x0, floor(min(pt.y))::integer AS y0,
                           (floor(max(pt.x)) - floor(min(pt.x)) + 1)::integer AS cols, (floor(max(pt.y)) - floor(min(pt.y)) + 1)::integer AS rows
                      FROM pt),
             -- (step 14e) the heights read District cell by District cell, only the cells the points lie in
             hd0 AS (SELECT DISTINCT floor(pt.x / g.dc)::integer AS dx, floor(pt.y / g.dc)::integer AS dy FROM pt),
             hd AS (SELECT q.dy, min(q.dx) AS x0, max(q.dx) AS x1
                      FROM (SELECT hd0.dx, hd0.dy, hd0.dx - row_number() OVER (PARTITION BY hd0.dy ORDER BY hd0.dx) AS run FROM hd0) q
                     GROUP BY q.dy, q.run),
             ht AS MATERIALIZED (SELECT h.x, h.y, h.height FROM hd
                                  CROSS JOIN LATERAL public.rpg_map_heights(7, (hd.x0 * g.dc)::integer, (hd.dy * g.dc)::integer, ((hd.x1 - hd.x0 + 1) * g.dc)::integer, g.dc::integer) h),
             -- the District grid cells round the points with water in or through them, and the cells beside those
             ad AS (SELECT floor(ab.x0 / g.dc)::integer - 1 AS x0, floor(ab.y0 / g.dc)::integer - 1 AS y0,
                           (floor((ab.x0 + ab.cols - 1) / g.dc) - floor(ab.x0 / g.dc) + 3)::integer AS cols,
                           (floor((ab.y0 + ab.rows - 1) / g.dc) - floor(ab.y0 / g.dc) + 3)::integer AS rows
                      FROM ab),
             dw AS MATERIALIZED (SELECT f.x, f.y FROM ad CROSS JOIN LATERAL public.rpg_map_flow(6, ad.x0, ad.y0, ad.cols, ad.rows) f
                                  WHERE f.depth > 0 OR f.line > 0),
             dn AS MATERIALIZED (SELECT DISTINCT dw.x + a AS x, dw.y + b AS y FROM dw CROSS JOIN generate_series(-1, 1) AS a CROSS JOIN generate_series(-1, 1) AS b),
             -- the points near water, and the battle grid's water under them
             pw AS MATERIALIZED (SELECT pt.* FROM pt JOIN dn ON dn.x = floor(pt.x / g.dc) AND dn.y = floor(pt.y / g.dc)),
             -- read only in the District cells those points lie in, a run of such cells along a row at a time
             aw0 AS (SELECT DISTINCT floor(pw.x / g.dc)::integer AS dx, floor(pw.y / g.dc)::integer AS dy FROM pw),
             aw AS (SELECT q.dy, min(q.dx) AS x0, max(q.dx) AS x1
                      FROM (SELECT aw0.dx, aw0.dy, aw0.dx - row_number() OVER (PARTITION BY aw0.dy ORDER BY aw0.dx) AS run FROM aw0) q
                     GROUP BY q.dy, q.run),
             wa AS MATERIALIZED (SELECT f.x, f.y FROM aw
                                  CROSS JOIN LATERAL public.rpg_map_flow(7, (aw.x0 * g.dc)::integer, (aw.dy * g.dc)::integer, ((aw.x1 - aw.x0 + 1) * g.dc)::integer, g.dc::integer) f
                                  WHERE f.depth > 0),
             wn AS MATERIALIZED (
               SELECT tw.town, w.x, w.y FROM tw CROSS JOIN ab CROSS JOIN LATERAL public.rpg_map_within(tw.card, 7, ab.x0, ab.y0, ab.cols, ab.rows) w
                WHERE tw.card IS NOT NULL AND EXISTS (SELECT 1 FROM hb WHERE hb.town = tw.town))
        SELECT v_ok || coalesce(jsonb_object_agg(b.base,
                 NOT EXISTS (SELECT 1 FROM pt
                               LEFT JOIN ht ON ht.x = floor(pt.x) AND ht.y = floor(pt.y)
                              WHERE pt.base = b.base
                                AND (coalesce(ht.height, -1e9) < g.sea
                                     OR CASE WHEN tw.card IS NULL
                                             THEN sqrt(power(pt.x - tw.mx, 2) + power(pt.y - tw.my, 2)) > public.rpg_map_town_edge(atan2(pt.y - tw.my, pt.x - tw.mx), tw.r, tw.shape)
                                             ELSE NOT EXISTS (SELECT 1 FROM wn WHERE wn.town = tw.town AND wn.x = floor(pt.x) AND wn.y = floor(pt.y)) END))
                 AND NOT EXISTS (SELECT 1 FROM pw JOIN wa ON wa.x = floor(pw.x) AND wa.y = floor(pw.y) WHERE pw.base = b.base)), '{}'::jsonb)
          INTO v_ok
          FROM (SELECT DISTINCT hb.base, hb.town FROM hb) b JOIN tw ON tw.town = b.town;
        PERFORM set_config('rpg.houseok', v_ok::text, true);
      END IF;
      SELECT coalesce(jsonb_agg(h ORDER BY n), '[]'::jsonb) INTO v_c
        FROM jsonb_array_elements(v_hb) WITH ORDINALITY AS e(h, n)
       WHERE (v_ok ->> (h ->> 'base'))::boolean;
    END IF;
    PERFORM set_config('rpg.houses', jsonb_set(v_all, ARRAY[v_key], v_c)::text, true);
  END IF;
  RETURN QUERY
  SELECT h.id, h.town, h.kind, h.roof, h.cx, h.cy, h.ux, h.uy, h.half_len, h.half_wide, h.eaves, h.pitch, h.storeys
    FROM jsonb_to_recordset(v_c) AS h(id text, town text, kind text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                      half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer);
END;
$function$;

-- (step 3) The squares of the battle grid a street, a lane or a market place inside a town or city runs over.
CREATE OR REPLACE FUNCTION public.rpg_map_street_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, class integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that the market place, a street or a lane inside a town, city or great
-- city runs over (step 3, Peter 2026-10-07 21:05: battle grids in a city should look like fighting in the streets):
-- the middle of the square within half its width of its line (rpg_map_town_streets, the one home of where they run,
-- classes 4, 5 and 6), as rpg_map_road_cells reads a road. class = the widest there (4 the market place, 5 a street, 6
-- a lane). The market place is an open square with straight ends (its squares lie between the ends of its line); a
-- street or lane is rounded at its ends like a road, and stops at a churchyard: no square of it within
-- map_street_churchyard_m of a church (rpg_map_buildings), the way streets went round churchyards. rpg_map_cells makes them road ground on dry land (a street stops
-- at a river: only the roads bridge it), and the Maps tab paves them. Only the battle grid has squares this small.
WITH tw AS MATERIALIZED (
       SELECT public.rpg_map_town_grounds(p_x0 - 25, p_y0 - 25, p_x0 + p_cols + 25, p_y0 + p_rows + 25) AS j WHERE p_level = 7),
     ts AS MATERIALIZED (SELECT public.rpg_map_town_streets(tw.j) AS j FROM tw WHERE jsonb_array_length(tw.j) > 0),
     -- a market place runs straight: it is read as one piece from end to end, so its edges and ends are true lines
     ln AS (SELECT (l ->> 'class')::integer AS class, (l ->> 'half')::double precision AS half,
                   CASE WHEN (l ->> 'class')::integer = 4 THEN jsonb_build_array(jsonb_build_array(0, 0, l -> 'ax', l -> 'ay'), jsonb_build_array(1, 0, l -> 'bx', l -> 'by'))
                        ELSE l -> 'pts' END AS pts, e.key || ':' || (l ->> 'k') AS id
              FROM ts CROSS JOIN LATERAL jsonb_each(ts.j) AS e CROSS JOIN LATERAL jsonb_array_elements(e.value -> 'lines') AS l
             WHERE (l ->> 'class')::integer >= 4),
     lp AS (SELECT ln.id, ln.class, ln.half, (p.v ->> 0)::integer AS n, (p.v ->> 2)::double precision AS x, (p.v ->> 3)::double precision AS y
              FROM ln CROSS JOIN LATERAL jsonb_array_elements(ln.pts) AS p(v)),
     -- the churches near the block, with their churchyards
     ch AS MATERIALIZED (
       SELECT b.cx, b.cy, b.ux, b.uy, b.half_len, b.half_wide,
              (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_street_churchyard_m')::double precision
              / (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_square_m')::double precision AS yard
         FROM public.rpg_map_buildings(p_level, p_x0, p_y0, p_cols, p_rows) b
        WHERE left(b.id, 1) IN ('c', 'k') AND EXISTS (SELECT 1 FROM ts)),
     sg AS (SELECT a.class, a.half, a.x AS ax, a.y AS ay, b.x AS bx, b.y AS by FROM lp a JOIN lp b ON b.id = a.id AND b.n = a.n + 1
             WHERE greatest(a.x, b.x) + a.half >= p_x0 AND least(a.x, b.x) - a.half <= p_x0 + p_cols
               AND greatest(a.y, b.y) + a.half >= p_y0 AND least(a.y, b.y) - a.half <= p_y0 + p_rows)
SELECT gx, gy, min(sg.class)
  FROM sg
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(least(sg.ax, sg.bx) - sg.half)::integer),
                                    least(p_x0 + p_cols - 1, floor(greatest(sg.ax, sg.bx) + sg.half)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(least(sg.ay, sg.by) - sg.half)::integer),
                                    least(p_y0 + p_rows - 1, floor(greatest(sg.ay, sg.by) + sg.half)::integer)) AS gy
 CROSS JOIN LATERAL (SELECT gx + 0.5 - sg.ax AS px, gy + 0.5 - sg.ay AS py, sg.bx - sg.ax AS dx, sg.by - sg.ay AS dy) v
 CROSS JOIN LATERAL (SELECT CASE WHEN v.dx * v.dx + v.dy * v.dy = 0 THEN 0
                                 ELSE least(greatest((v.px * v.dx + v.py * v.dy) / (v.dx * v.dx + v.dy * v.dy), 0), 1) END AS t) t
 WHERE power(v.px - t.t * v.dx, 2) + power(v.py - t.t * v.dy, 2) <= sg.half * sg.half
   AND (sg.class <> 4 OR (v.px * v.dx + v.py * v.dy BETWEEN 0 AND v.dx * v.dx + v.dy * v.dy))
   AND (sg.class = 4 OR NOT EXISTS (
         SELECT 1 FROM ch
          WHERE abs((gx + 0.5 - ch.cx) * ch.ux + (gy + 0.5 - ch.cy) * ch.uy) <= ch.half_len + ch.yard
            AND abs((gy + 0.5 - ch.cy) * ch.ux - (gx + 0.5 - ch.cx) * ch.uy) <= ch.half_wide + ch.yard))
 GROUP BY gx, gy;
$function$;

-- (step 3) Building insides on the battle grid: the one home of every square a building stands on, its walls, its
-- doors, its inside walls and its floors; rpg_map_building_cells keeps its job (the squares that are climbed) and reads
-- its building squares from here.
CREATE OR REPLACE FUNCTION public.rpg_map_building_squares(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Every square of a block of the battle grid that a building stands on (rpg_map_buildings, the one home of where
-- buildings stand), as a floor plan (step 3, Peter 2026-10-07 21:05: battle grids in a city should look like fighting
-- in the streets or inside buildings): every square whose middle lies inside a part of a building. part:
--   wall   the squares within one square of the building's outer edge: climbed, sheer (90 degrees) to its eaves, as
--   masonry before (step 8c; rpg_map_climb_by: a house 2.6 m to its eaves, difficulty 10); masonry for the stone walls
--          of a church or the cathedral, wall for the timber-framed walls of a house or a barn.
--   door   a wall square where a door is: walked like the ground. A door is map_house_door_m wide (1.2 m; a square at
--          least), a barn's and a cathedral's west door twice that. Where the doors go (the front is the side of the
--          building facing its street, toward the square on the street its plot is counted from):
--            a house whose long side faces the street: its cross passage, a front and a back door opposite each other,
--              one bay in from one end (rolled, part 12 layer 1291), the medieval house plan of a hall with a passage
--              at its lower end (Wood 1965, The English Mediaeval House; Grenville 1997, Medieval Housing);
--            a house whose gable end faces the street (a town house on a narrow plot): a door in that end beside its
--              passage side (layer 1292) and one in the back end in line with it (Pantin 1962);
--            a barn: cart doors in the middle of both long sides, the threshing floor between (Brunskill 1982);
--            a church: a south and a north door near the west end of its nave; its tower and chancel open off the nave
--              (Morris 1989);
--            a cathedral: a great west door in the middle of the nave's west end, and a door at each end of the
--              transepts.
--   inner  a wall inside a house, one storey high and climbed like a wall: a house is framed in bays
--          (map_house_bay_m, 4.6 m), so a house of two bays has one cross wall in its middle, of three or more a cross
--          wall one bay in from each end (the service end and the chamber end, the hall between: Wood 1965); each has a
--          doorway in its middle.
--   floor  the rest of a house or a barn (boards and beaten earth), walked like the ground;
--   flags  the rest of a church or the cathedral (stone flags), walked like the ground.
-- A building of several parts (a house and its back range, a church's nave, chancel and tower) is one floor plan: a
-- square inside one part is its floor even where it lies on the edge of another, so the walls run round the whole
-- building and the parts open into each other; each square comes once (inside first, then a door, then a wall; of a
-- kind, the part it lies furthest inside). angle, rise, difficulty and pct as rpg_map_climb_by gives them for a wall
-- or an inner wall; nothing for a square walked like the ground (a door, a floor, flags).
WITH cfg AS (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_square_m')::double precision AS sq,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_bay_m')::double precision AS bay,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_house_door_m')::double precision AS door,
                    (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_seed')::integer AS seed),
     h AS MATERIALIZED (
       SELECT b.*, left(b.id, 1) AS pre, coalesce(nullif(split_part(b.id, '.', 2), ''), '') AS suf,
              cw.rise AS w_rise, cw.difficulty AS w_dif, cw.pct AS w_pct, ci.rise AS i_rise, ci.difficulty AS i_dif, ci.pct AS i_pct,
              -- the square on the street its plot is counted from (in its id: h<road>-<x>-<y><side>)
              split_part(split_part(b.id, '.', 1), '-', 2)::double precision AS sx,
              rtrim(split_part(split_part(b.id, '.', 1), '-', 3), 'lr')::double precision AS sy
         FROM public.rpg_map_buildings(p_level, p_x0, p_y0, p_cols, p_rows) b
        CROSS JOIN LATERAL public.rpg_map_climb_by(90, b.eaves) cw
        CROSS JOIN LATERAL public.rpg_map_climb_by(90, b.eaves / greatest(b.storeys, 1)) ci),
     -- each part's doors and inside walls, in its own measure: a along its ridge (ux, uy), b across it; fa, fb = the
     -- way to its street; dh = half a door's width, in squares
     hp AS (
       SELECT h.*, f.fa, f.fb, abs(f.fb) * h.half_len >= abs(f.fa) * h.half_wide AS long_front,
              (cfg.door / cfg.sq) / 2 AS dh, cfg.bay / cfg.sq AS bay,
              greatest(round(2 * h.half_len * cfg.sq / cfg.bay), 1)::integer AS bays,
              (public.rpg_map_roll(cfg.seed, 1291, round(h.sx)::integer, round(h.sy)::integer) - 1) / 99.0 AS r1,
              (public.rpg_map_roll(cfg.seed, 1292, round(h.sx)::integer, round(h.sy)::integer) - 1) / 99.0 AS r2
         FROM h CROSS JOIN cfg
        CROSS JOIN LATERAL (SELECT (h.sx + 0.5 - h.cx) * h.ux + (h.sy + 0.5 - h.cy) * h.uy AS fa,
                                   (h.sy + 0.5 - h.cy) * h.ux - (h.sx + 0.5 - h.cx) * h.uy AS fb) f),
     -- doors: [face (a = across the ends, b = along the long sides), side (1, -1, or 0 both), where along the face, half width]
     dr AS (
       SELECT hp.id, d.face, d.side, d.at, d.half
         FROM hp
        CROSS JOIN LATERAL (
          -- a house, its long side to the street: the cross passage, front and back, one bay in from an end
          SELECT 'b' AS face, 0 AS side,
                 CASE WHEN hp.bays <= 1 THEN 0 ELSE CASE WHEN hp.r1 < 0.5 THEN -1 ELSE 1 END * greatest(hp.half_len - hp.bay + hp.dh, 0) END AS at, hp.dh AS half
           WHERE hp.pre = 'h' AND hp.suf = '' AND hp.long_front
          UNION ALL
          -- a house, its gable end to the street: front and back ends, beside the passage side
          SELECT 'a', 0, CASE WHEN hp.half_wide < 1.5 THEN 0 ELSE CASE WHEN hp.r2 < 0.5 THEN -1 ELSE 1 END * (hp.half_wide - 1 - hp.dh) END, hp.dh
           WHERE hp.pre = 'h' AND hp.suf = '' AND NOT hp.long_front
          UNION ALL
          -- a barn: cart doors mid-way along both long sides
          SELECT 'b', 0, 0, 2 * hp.dh WHERE hp.pre = 'b'
          UNION ALL
          -- a church: south and north doors near the west end of the nave (a runs east)
          SELECT 'b', 0, -hp.half_len + 1 + hp.dh, hp.dh WHERE hp.pre = 'c' AND hp.suf = ''
          UNION ALL
          -- a cathedral: the great west door, and doors at the ends of the transepts
          SELECT 'a', -1, 0, 2 * hp.dh WHERE hp.pre = 'k' AND hp.suf = ''
          UNION ALL
          SELECT 'a', 0, 0, hp.dh WHERE hp.pre = 'k' AND hp.suf = 'x') d),
     -- inside walls of a house (and its back range): where along it, in squares from its middle
     iw AS (
       SELECT hp.id, w.at
         FROM hp
        CROSS JOIN LATERAL (SELECT 0::double precision AS at WHERE hp.bays = 2
                            UNION ALL
                            SELECT s * (hp.half_len - hp.bay) FROM (VALUES (-1), (1)) AS v(s) WHERE hp.bays >= 3) w
        WHERE hp.pre = 'h'),
     sqs AS (
       SELECT gx, gy, hp.id, hp.pre, l.a, l.b, q.wall,
              least(hp.half_len - abs(l.a), hp.half_wide - abs(l.b)) AS depth,
              q.wall AND EXISTS (SELECT 1 FROM dr
                                  WHERE dr.id = hp.id
                                    AND CASE WHEN dr.face = 'b'
                                             THEN abs(l.b) > hp.half_wide - 1 AND (dr.side = 0 OR sign(l.b) = dr.side) AND abs(l.a - dr.at) <= greatest(dr.half, 0.5)
                                                  AND abs(l.a) <= hp.half_len - 1
                                             ELSE abs(l.a) > hp.half_len - 1 AND (dr.side = 0 OR sign(l.a) = dr.side) AND abs(l.b - dr.at) <= greatest(dr.half, 0.5)
                                                  AND abs(l.b) <= hp.half_wide - 1 END) AS door,
              NOT q.wall AND EXISTS (SELECT 1 FROM iw WHERE iw.id = hp.id AND abs(l.a - iw.at) <= 0.5 AND abs(l.b) > hp.dh + 0.5) AS inner,
              hp.w_rise, hp.w_dif, hp.w_pct, hp.i_rise, hp.i_dif, hp.i_pct
         FROM hp
        CROSS JOIN LATERAL (SELECT hp.half_len * abs(hp.ux) + hp.half_wide * abs(hp.uy) AS ex, hp.half_len * abs(hp.uy) + hp.half_wide * abs(hp.ux) AS ey) e
        CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(hp.cx - e.ex)::integer), least(p_x0 + p_cols - 1, floor(hp.cx + e.ex)::integer)) AS gx
        CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(hp.cy - e.ey)::integer), least(p_y0 + p_rows - 1, floor(hp.cy + e.ey)::integer)) AS gy
        -- the middle of the square, measured along the part and across it
        CROSS JOIN LATERAL (SELECT (gx + 0.5 - hp.cx) * hp.ux + (gy + 0.5 - hp.cy) * hp.uy AS a, (gy + 0.5 - hp.cy) * hp.ux - (gx + 0.5 - hp.cx) * hp.uy AS b) l
        CROSS JOIN LATERAL (SELECT abs(l.a) > hp.half_len - 1 OR abs(l.b) > hp.half_wide - 1 AS wall) q
        WHERE abs(l.a) <= hp.half_len AND abs(l.b) <= hp.half_wide)
SELECT DISTINCT ON (sqs.gx, sqs.gy) sqs.gx, sqs.gy, sqs.id,
       CASE WHEN sqs.door THEN 'door' WHEN sqs.wall AND sqs.pre IN ('c', 'k') THEN 'masonry' WHEN sqs.wall THEN 'wall' WHEN sqs.inner THEN 'inner'
            WHEN sqs.pre IN ('c', 'k') THEN 'flags' ELSE 'floor' END,
       CASE WHEN sqs.wall AND NOT sqs.door OR sqs.inner THEN 90::double precision END,
       CASE WHEN sqs.door THEN NULL WHEN sqs.wall THEN sqs.w_rise WHEN sqs.inner THEN sqs.i_rise END,
       CASE WHEN sqs.door THEN NULL WHEN sqs.wall THEN sqs.w_dif WHEN sqs.inner THEN sqs.i_dif END,
       CASE WHEN sqs.door THEN NULL WHEN sqs.wall THEN sqs.w_pct WHEN sqs.inner THEN sqs.i_pct END
  FROM sqs
 ORDER BY sqs.gx, sqs.gy, sqs.wall, sqs.door DESC, sqs.depth DESC, sqs.id;
$function$;

-- The squares that are climbed keep their one home here (step 8c), now the walls and inside walls of the floor plans
-- (rpg_map_building_squares) and, as before, the climbed squares of the landmarks and places to go into.
CREATE OR REPLACE FUNCTION public.rpg_map_building_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that are climbed where something built stands (step 8c): the walls of a
-- building (rpg_map_building_squares: its outer walls, sheer to its eaves, and its inside walls, one storey; step 3:
-- its doors and floors are walked like the ground, so they are not here), climbed by the Climbing rule
-- (rpg_map_climb_by, Peter 2026-10-03 23:12: the climbing rule goes for any steep surface, buildings too). angle = how
-- steep, rise = metres climbed, difficulty of the Climbing roll, pct = the percent of time it adds to the square.
-- Ground underneath is whatever rpg_map_cells says; the costs of a block (rpg_map_costs), the climb on a move
-- (rpg_climb_check), where a walk may end (rpg_map_walk), where a creature is set down (rpg_map_set_down) and the Maps
-- tab all read it. The squares a landmark stands on come with them (step 12b2; rpg_map_landmark_cells): a castle wall,
-- a keep, a tower, a ruined wall, a standing stone, a boulder, a cairn or the side of a motte, each climbed the same
-- way, its id the id of the landmark (mark-<x>-<y>); and those of a place to go into (step 12c), but for its squares
-- with no climb (a floor, a hearth, an altar, a mouth), which are walked like the ground.
SELECT b.x, b.y, b.id, b.part, b.angle, b.rise, b.difficulty, b.pct
  FROM public.rpg_map_building_squares(p_level, p_x0, p_y0, p_cols, p_rows) b
 WHERE b.angle IS NOT NULL
UNION ALL
SELECT m.x, m.y, m.id, m.part, m.angle, m.rise, m.difficulty, m.pct
  FROM public.rpg_map_landmark_cells(p_level, p_x0, p_y0, p_cols, p_rows) m
 WHERE m.angle IS NOT NULL;
$function$;

-- (step 3) the words for the walls of a building and the walls inside it
CREATE OR REPLACE FUNCTION public.rpg_map_climb_words(p_part text, p_angle double precision)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- What a steep square is, in words (step 12b2), the one home of them: the wall of a building or a wall inside it
-- (step 3; step 8c had houses' walls and roofs), the parts of a landmark or a place to go into
-- (rpg_map_landmark_squares; step 12c), or a cliff (part nothing). Read by the climb on a move (rpg_climb_check) and by
-- the Maps tab (rpg_map_view_block: the climb of each cell).
SELECT CASE p_part WHEN 'wall' THEN 'the wall of a building' WHEN 'masonry' THEN 'the stone wall of a church' WHEN 'inner' THEN 'a wall inside a building'
                   WHEN 'roof' THEN 'a ' || round(p_angle) || '-degree roof'
                   WHEN 'keep' THEN 'the keep of a castle' WHEN 'curtain' THEN 'the wall of a castle' WHEN 'tower' THEN 'a stone tower'
                   WHEN 'ruin' THEN 'a ruined wall' WHEN 'stone' THEN 'a standing stone' WHEN 'boulder' THEN 'a boulder'
                   WHEN 'cairn' THEN 'a cairn' WHEN 'mound' THEN 'the side of a motte'
                   WHEN 'hut' THEN 'the wall of a hut' WHEN 'shrine' THEN 'the wall of a shrine' WHEN 'cross' THEN 'a wayside cross'
                   WHEN 'outcrop' THEN 'a rock outcrop' WHEN 'spoil' THEN 'a spoil heap' WHEN 'palisade' THEN 'a palisade'
                   WHEN 'tent' THEN 'a tent'
                   ELSE 'a ' || round(p_angle) || '-degree cliff' END;
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
       SELECT w.x, w.y, w.depth FROM public.rpg_map_water(p_level, p_x0, p_y0, p_cols, p_rows) w),
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
 GROUP BY g.gx, g.gy, g.dry, g.kind, wt.depth, cfg.swim, tc.x, rd.x, st.x, fd.x
 ORDER BY g.gy, g.gx;
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
-- (step 3) A building is a floor plan on the battle grid (rpg_map_building_squares): its walls and inside walls carry
-- climb (part wall or inner), its doors and floors feature = door, floor (a house or a barn) or flags (a church or the
-- cathedral), walked like the ground. A square of a town or city that a road, its market place, a street or a lane
-- runs over (road ground) carries place = the settlement and paved = 1 (2 the market place), so the page paves it;
-- a village's lanes stay earth.
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
  v_hlist     jsonb;
  v_hpend     boolean := false;
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
       -- the battle grid: the squares of a place to go into walked like the ground (step 12c), one each, and (step 3) the
       -- doors and floors of the buildings, where the block has a building
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part, f.house
                             FROM (SELECT f.x, f.y, f.part, NULL::text AS house FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                                    WHERE v_l.level = 7 AND f.angle IS NULL
                                   UNION ALL
                                   SELECT b.x, b.y, b.part, b.id FROM public.rpg_map_building_squares(v_l.level, v_x0, v_y0, v_cols, v_rows) b
                                    WHERE v_l.level = 7 AND b.angle IS NULL AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))) f
                            ORDER BY f.x, f.y, f.part),
       -- the battle grid: the market place's squares (step 3)
       mk AS MATERIALIZED (SELECT s.x, s.y FROM public.rpg_map_street_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) s
                            WHERE v_l.level = 7 AND s.class = 4 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
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
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks,
                CASE WHEN c.kind = 'town' OR (v_l.level = 7 AND c.kind IN ('road', 'pass')) THEN tg.id END AS town,
                -- (step 3) a road, market place, street or lane square of a town, city or great city is paved
                CASE WHEN v_l.level = 7 AND c.kind IN ('road', 'pass') AND tg.kind IN ('town', 'city', 'great_city')
                     THEN CASE WHEN mk.x IS NOT NULL THEN 2 ELSE 1 END END AS paved,
                coalesce(hb.id, ft.house) AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
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
           LEFT JOIN mk ON mk.x = c.x AND mk.y = c.y
          CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
          -- the cell itself counted round the world, for a block that runs past the east or west end
          CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx)
  SELECT (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'x', cl.x - v_x0 + 1, 'y', cl.y - v_y0 + 1,
                   'name', public.rpg_square_name(cl.x - v_x0 + 1, cl.y - v_y0 + 1),
                   -- a cell of a village, town or city comes as a place, its place the settlement, so it is drawn and
                   -- named like a place with ground
                   'kind', CASE WHEN NOT cl.seen THEN 'unknown' WHEN cl.town IS NOT NULL AND cl.kind = 'town' THEN 'place' ELSE cl.kind END,
                   -- (step 3) a paved square of a town or city: 1 a street, 2 the market place
                   'paved', CASE WHEN cl.seen THEN cl.paved END,
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
           -- (step 14f1) a great river over the sea too: it runs on into the sea cell it flows into, and the Maps tab clips
           -- every river to the coast it draws, so its mouth meets the shore at every zoom
           WHERE cl.seen AND cl.kind NOT IN ('water', 'deep') AND (cl.kind <> 'sea' OR r.k = 2)),
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
             -- (step 14e) what the building is (its id's first letter: h a house, b a barn, c a church, k a cathedral) and
             -- which of its parts this is (the letter after the dot; none for the first part)
             'use', CASE left(h.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(h.id, '.', 2), ''),
             'x', round((h.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((h.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(h.ux * 1000)::integer, round(h.uy * 1000)::integer),
             'len', round(2 * h.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * h.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(h.eaves::numeric, 1), 'pitch', round(h.pitch)::integer, 'storeys', h.storeys) ORDER BY h.id)
      INTO v_houses
      FROM public.rpg_map_buildings(v_l.level, v_x0, v_y0, v_cols, v_rows) h
     -- every part of a building with a square seen (step 14e)
     WHERE split_part(h.id, '.', 1) IN (SELECT split_part(x, '.', 1) FROM unnest(v_hseen) AS x);
  END IF;

  -- the buildings of the District grid (step 14e, Peter 2026-10-07 21:05: cities need more building variety; the City
  -- and District grids show real buildings): the same buildings as the battle grids under it, saved on the grid's row
  -- of the saved map once worked out in the background (rpg_map_district_buildings; a great city's take longer than a
  -- read may run). Each drawn whole where the kids login has found a cell any part of it stands in; x, y, len and wide
  -- in thousandths of a District cell. Not saved yet: houses_pending, and the Maps tab draws the town symbols and asks
  -- again a few seconds later.
  IF v_l.level = 6 THEN
    v_hlist := public.rpg_map_district_buildings(v_x0, v_y0, v_cols, v_rows);
    v_hpend := v_hlist IS NULL;
  END IF;
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH b AS MATERIALIZED (
           SELECT h.* FROM jsonb_to_recordset(v_hlist) AS h(id text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                            half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer)),
         sc AS (SELECT (c.v ->> 'x')::integer AS x, (c.v ->> 'y')::integer AS y FROM jsonb_array_elements(coalesce(v_cells, '[]'::jsonb)) AS c(v)
                 WHERE c.v ->> 'kind' IS DISTINCT FROM 'unknown'),
         sb AS (SELECT DISTINCT split_part(b.id, '.', 1) AS base FROM b
                 WHERE v_gm OR EXISTS (SELECT 1 FROM sc WHERE sc.x = floor((b.cx - v_gx0) / v_l.cell)::integer + 1 AND sc.y = floor((b.cy - v_gy0) / v_l.cell)::integer + 1))
    SELECT jsonb_agg(jsonb_build_object(
             'id', b.id, 'roof', b.roof,
             'use', CASE left(b.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(b.id, '.', 2), ''),
             'x', round((b.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((b.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(b.ux * 1000)::integer, round(b.uy * 1000)::integer),
             'len', round(2 * b.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * b.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(b.eaves::numeric, 1), 'pitch', round(b.pitch)::integer, 'storeys', b.storeys) ORDER BY b.id)
      INTO v_houses
      FROM b WHERE split_part(b.id, '.', 1) IN (SELECT sb.base FROM sb);
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
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
       AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width', 'map_road_4_width', 'map_road_5_width', 'map_road_6_width');
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

  -- (step 3) the District grid's streets: the market places, streets and lanes inside its towns and cities, saved with
  -- its buildings (rpg_map_district_buildings, notes: streets), drawn among the roads as pieces [4 the market place,
  -- its width, x0, y0, ...] and [5 a street or 6 a lane, x0, y0, ...] in thousandths of a District cell (road_width
  -- carries the width of a street and a lane), cut where they leave the cells the kids login has found
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH sv AS (SELECT m.notes -> 'streets' AS j
                  FROM public.rpg_map_cache_grids(6, v_x0, v_y0, v_cols, v_rows) g
                  JOIN public.rpg_map_cache m ON m.level = 6 AND m.gx = g.gx AND m.gy = g.gy LIMIT 1),
         sl AS (SELECT e.v, e.o, (e.v ->> 0)::integer AS class, (e.v ->> 1)::double precision AS half
                  FROM sv CROSS JOIN LATERAL jsonb_array_elements(coalesce(sv.j, '[]'::jsonb)) WITH ORDINALITY AS e(v, o)),
         sp AS (SELECT sl.o, sl.class, sl.half, k.i, (sl.v ->> (2 * k.i + 2))::double precision AS x, (sl.v ->> (2 * k.i + 3))::double precision AS y
                  FROM sl CROSS JOIN LATERAL generate_series(0, (jsonb_array_length(sl.v) - 2) / 2 - 1) AS k(i)),
         sk AS (SELECT sp.*, v_gm OR coalesce(v_shown, '{}'::jsonb) ? (floor(sp.x / v_l.cell)::bigint || ',' || floor(sp.y / v_l.cell)::bigint) AS ok FROM sp),
         sr AS (SELECT sk.*, sum(CASE WHEN sk.ok THEN 0 ELSE 1 END) OVER (PARTITION BY sk.o ORDER BY sk.i) AS run FROM sk)
    SELECT coalesce(v_roads, '[]'::jsonb) || coalesce(jsonb_agg(q.piece ORDER BY q.class, q.o, q.run), '[]'::jsonb) INTO v_roads
      FROM (SELECT sr.o, sr.class, sr.run,
                   CASE WHEN sr.class = 4 THEN jsonb_build_array(4, round(2 * sr.half * 1000 / v_l.cell)::integer) ELSE jsonb_build_array(sr.class) END
                   || jsonb_agg(v.c ORDER BY sr.i, v.n) AS piece
              FROM sr CROSS JOIN LATERAL (VALUES (1, round((sr.x - v_gx0) * 1000 / v_l.cell)::integer), (2, round((sr.y - v_gy0) * 1000 / v_l.cell)::integer)) AS v(n, c)
             WHERE sr.ok GROUP BY sr.o, sr.class, sr.half, sr.run HAVING count(*) >= 4) q;
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
    'houses', CASE WHEN v_hpend THEN NULL ELSE coalesce(v_houses, '[]'::jsonb) END, 'houses_pending', v_hpend,
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'under', v_under,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_district_buildings(p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_make boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The buildings of a District grid, saved on its row of the saved map (rpg_map_cache level 6, notes: houses) the first
-- time they are worked out (step 14e, 2026-10-07: Peter opened a District grid in the great city of Neneborough and it
-- failed with a statement timeout; working out a great city's buildings over a whole District grid takes 5 to 10
-- seconds, past the 8 a login may run a read). The block is the District grid in District cells (p_x0, p_y0, p_cols,
-- p_rows, as rpg_map_view_block reads it). Every building whose part reaches the grid, from rpg_map_buildings (the one
-- home of where buildings stand), as rows: id, roof, cx, cy (world squares), ux, uy, half_len, half_wide (squares),
-- eaves, pitch, storeys. With p_make false (the map): the saved list, or null when it is not saved yet, in which case
-- one background call (as the service login, which may run 3 minutes) is sent to work it out and save it, at most once
-- a minute for a grid. With p_make true (that background call): works it out and saves it if not saved yet. The saved
-- map is cleared whenever a setting or a place card changes (rpg_map_cache_watch), so the buildings follow every change.
-- (step 3) The same save keeps the streets of the grid (notes: streets): every market place, street and lane inside a
-- town or city that reaches it (rpg_map_town_streets, the one home of where they run), each [class (4 the market place,
-- 5 a street, 6 a lane), half its width, then the points of its line, x, y in world squares], its points cut to the grid
-- and a little round it, so the Maps tab draws the streets the battle grids under it pave without working them out.
DECLARE
  v_cell integer;
  g record;
  v_notes jsonb;
  v_list jsonb;
  v_streets jsonb;
  v_key text;
BEGIN
  SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = 6;
  SELECT q.* INTO g FROM public.rpg_map_cache_grids(6, p_x0, p_y0, p_cols, p_rows) q LIMIT 1;
  IF g.gx IS NULL THEN RETURN NULL; END IF;
  PERFORM public.rpg_map_cache_fill(6, p_x0, p_y0, p_cols, p_rows);
  SELECT m.notes INTO v_notes FROM public.rpg_map_cache m WHERE m.level = 6 AND m.gx = g.gx AND m.gy = g.gy;
  IF v_notes ? 'houses' THEN RETURN v_notes -> 'houses'; END IF;
  IF NOT p_make THEN
    IF coalesce((v_notes ->> 'houses_asked')::timestamptz, '-infinity'::timestamptz) < now() - interval '1 minute' THEN
      UPDATE public.rpg_map_cache m SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('houses_asked', now())
       WHERE m.level = 6 AND m.gx = g.gx AND m.gy = g.gy;
      SELECT s.setting_value INTO v_key FROM public.settings s
       WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = 'supabase_service_role_key';
      IF v_key IS NOT NULL THEN
        PERFORM net.http_post(
          url := 'https://vulhdujhbwvibbojiimi.supabase.co/rest/v1/rpc/rpg_map_district_buildings',
          headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
          body := jsonb_build_object('p_x0', p_x0, 'p_y0', p_y0, 'p_cols', p_cols, 'p_rows', p_rows, 'p_make', true),
          timeout_milliseconds := 120000);
      END IF;
    END IF;
    RETURN NULL;
  END IF;
  -- (2026-10-07 23:18) one grid worked out at a time: several at once (Peter browsing a great city) slowed every other
  -- read until maps timed out; a call that finds another one running leaves this grid to the map's next ask
  IF NOT pg_try_advisory_xact_lock(hashtext('rpg_map_district_buildings')) THEN
    UPDATE public.rpg_map_cache m SET notes = coalesce(m.notes, '{}'::jsonb) - 'houses_asked'
     WHERE m.level = 6 AND m.gx = g.gx AND m.gy = g.gy;
    RETURN NULL;
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'roof', b.roof, 'cx', b.cx, 'cy', b.cy, 'ux', b.ux, 'uy', b.uy,
                                               'half_len', b.half_len, 'half_wide', b.half_wide, 'eaves', b.eaves, 'pitch', b.pitch,
                                               'storeys', b.storeys) ORDER BY b.id), '[]'::jsonb)
    INTO v_list
    FROM public.rpg_map_buildings(7, (p_x0 * v_cell)::integer, (p_y0 * v_cell)::integer, (p_cols * v_cell)::integer, (p_rows * v_cell)::integer) b;
  -- (step 3) its streets: the points of each line within 40 squares of the grid, the market place by its two ends
  WITH b AS (SELECT (p_x0 * v_cell - 40)::double precision AS x0, (p_y0 * v_cell - 40)::double precision AS y0,
                    ((p_x0 + p_cols) * v_cell + 40)::double precision AS x1, ((p_y0 + p_rows) * v_cell + 40)::double precision AS y1),
       ts AS (SELECT public.rpg_map_town_streets(public.rpg_map_town_grounds(b.x0, b.y0, b.x1, b.y1)) AS j FROM b),
       ln AS (SELECT l, (l ->> 'class')::integer AS class, (l ->> 'half')::double precision AS half
                FROM ts CROSS JOIN LATERAL jsonb_each(ts.j) AS e CROSS JOIN LATERAL jsonb_array_elements(e.value -> 'lines') AS l
               WHERE (l ->> 'class')::integer >= 4),
       pt AS (SELECT ln.l, ln.class, ln.half, q.n, q.x, q.y
                FROM ln CROSS JOIN b
               CROSS JOIN LATERAL (SELECT (p ->> 0)::integer AS n, (p ->> 2)::double precision AS x, (p ->> 3)::double precision AS y
                                     FROM jsonb_array_elements(CASE WHEN ln.class = 4
                                                                    THEN jsonb_build_array(jsonb_build_array(0, 0, ln.l -> 'ax', ln.l -> 'ay'), jsonb_build_array(1, 0, ln.l -> 'bx', ln.l -> 'by'))
                                                                    ELSE ln.l -> 'pts' END) AS p) q
               WHERE ln.class = 4 OR (q.x BETWEEN b.x0 AND b.x1 AND q.y BETWEEN b.y0 AND b.y1))
  SELECT coalesce(jsonb_agg(q.e), '[]'::jsonb) INTO v_streets
    FROM (SELECT jsonb_build_array(pt.class, round(pt.half::numeric, 2)) || jsonb_agg(v.c ORDER BY pt.n, v.i) AS e
            FROM pt CROSS JOIN LATERAL (VALUES (1, round(pt.x::numeric, 1)), (2, round(pt.y::numeric, 1))) AS v(i, c)
           GROUP BY pt.l, pt.class, pt.half HAVING count(*) >= 4) q;
  UPDATE public.rpg_map_cache m SET notes = (coalesce(m.notes, '{}'::jsonb) - 'houses_asked') || jsonb_build_object('houses', v_list, 'streets', v_streets)
   WHERE m.level = 6 AND m.gx = g.gx AND m.gy = g.gy;
  RETURN v_list;
END;
$function$;

-- (step 3) the world map rule card: the streets, the market place and building insides, two passages swapped in place
-- (the admin manual page is written from it by its trigger)
UPDATE public.rpg_rules
   SET body = replace(replace(body, $a1$On the battle grid their houses stand along the roads that run through them, one household$a1$, $b1$On the battle grid a town or city has a market place at its middle, its main road widened to 16 to 40 m across for 60 to 220 m, and streets running behind the main road with lanes across them, as much street as its households need frontage for: a city of 12,000 people (2,667 households of 4.5) on plots of 1.25 perches needs 2,667 × 6.3 m ÷ 2 = 8.4 km of street, both sides lined; less the roads and the market place already there. The streets lie 50 m apart at the middle and further apart toward the edge (up to 100 m), as the plots near the market filled first. Streets (about 5 m wide) and the market place are paved and walked like a road; lanes are about 2.8 m wide; a street stops at the water and at a churchyard. Houses stand along the roads, the market place and the streets, one household$b1$), $a2$Houses are climbed (see Climbing), barns and churches the same way (a church tower 25 m high is a 25 m wall); a walk goes round them.$a2$, $b2$On the battle grid a building is seen inside. Its outer walls are climbed (see Climbing: a house 2.6 m to its eaves is a 2.6 m sheer wall, Climbing against 10; a church tower 25 m high a 25 m wall), and so are the walls inside a house, one storey high; its doors and floors are walked like the ground. A house whose long side faces its street has a front and a back door opposite each other one bay in from one end (a 3-bay house, 13.8 m long, has them 4.6 m from that end); a house whose gable faces the street has a door in each end beside its passage. A house of 2 bays has a cross wall in its middle, of 3 or more a cross wall one bay in from each end with the hall between, each with a doorway in its middle. A barn has cart doors 2.4 m wide in the middle of both long sides; a church a south and a north door near the west end of its nave; a cathedral a great west door and a door at each end of its transepts. A door is 1.2 m wide.$b2$), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position($a1$On the battle grid their houses stand along the roads that run through them, one household$a1$ in body) > 0 AND position($a2$Houses are climbed (see Climbing), barns and churches the same way (a church tower 25 m high is a 25 m wall); a walk goes round them.$a2$ in body) > 0;

REVOKE ALL ON FUNCTION public.rpg_map_town_grounds(double precision, double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_town_grounds(double precision, double precision, double precision, double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_town_streets(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_town_streets(jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_street_cells(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_street_cells(integer, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_building_squares(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_building_squares(integer, integer, integer, integer, integer) TO service_role;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

