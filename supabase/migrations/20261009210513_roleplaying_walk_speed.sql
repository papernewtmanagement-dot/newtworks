-- Walk speed step (Peter 2026-10-09 defaults, 1A): walks read their cliffs once for the whole walk, only the steep squares get an angle,
-- and a walk that times out sends its ground to be worked out in the background, then the Maps tab tries it again.
CREATE OR REPLACE FUNCTION public.rpg_map_cliffs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, mountains double precision, hills double precision, gorge integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cliffs of a block of the battle grid, worked out when asked and never stored: the one home of which squares are
-- rock to climb and how steep (rpg_map_cliff, rpg_map_costs, rpg_map_walk and rpg_map_view_block read it, each with the
-- square's own ground: mountains = how steep the square is when it is mountains, hills = when it is hills; any other
-- ground has no cliffs).
-- Two kinds of cliff (step 7c; canyons, Peter 2026-10-09: when rivers run through hills or mountains that would create
-- canyons):
--  * a mountain square whose steep (rpg_map_steep) is in the top map_cliff_share, at its own angle (rpg_map_cliff_angle);
--  * the wall of a gorge: a hills or mountains square beside a river (rpg_map_river_line: great rivers, rivers and
--    streams; a brook cuts no gorge), out to the rim. The gorge is map_gorge_depth_K metres deep in hills (great river 40,
--    river 25, stream 8) and map_gorge_mountain_times (3) that in mountains (120, 75, 24); its walls stand at
--    map_gorge_angle_hills (55 degrees) or map_gorge_angle_mountains (70), so each wall reaches depth / tan(angle) past
--    the bank (half the river wide from its middle line): a river in hills 25 m / tan 55 = 17.5 m, 16 squares each side;
--    in mountains 75 m / tan 70 = 27.3 m, 24 squares.
-- Where both meet the steeper wins. gorge = the size of river whose gorge wall the square is (2 great river, 3 river,
-- 4 stream; nothing when it is no gorge wall). Only the battle grid has cliffs: a coarser grid's cells are walked at
-- their ground's own time. Squares with no cliff on either ground have no row.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
               AND (s.key LIKE 'map\_gorge\_%' OR s.key LIKE 'map\_river\__\_width' OR s.key = 'map_square_m')),
     cf AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_hills')::double precision AS ah,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_mountains')::double precision AS am,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_mountain_times')::double precision AS times,
                   (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq),
     -- each size of river and ground: half the river wide, how deep its gorge, how steep and how far past the bank its
     -- wall reaches, in squares
     kw AS (SELECT w.k, g.kind, (SELECT st.value FROM st WHERE st.key = 'map_river_' || w.k || '_width')::double precision / 2 AS half,
                   d.depth, a.angle, d.depth / tan(radians(a.angle)) / cf.sq AS wall
              FROM generate_series(2, 5) AS w(k) CROSS JOIN cf
             CROSS JOIN (VALUES ('hills'), ('mountains')) AS g(kind)
             CROSS JOIN LATERAL (SELECT coalesce((SELECT st.value FROM st WHERE st.key = 'map_gorge_depth_' || w.k)::double precision, 0)
                                        * CASE WHEN g.kind = 'mountains' THEN cf.times ELSE 1 END AS depth) d
             CROSS JOIN LATERAL (SELECT CASE WHEN g.kind = 'mountains' THEN cf.am ELSE cf.ah END AS angle) a
             WHERE d.depth > 0 AND p_level = 7),
     kr AS (SELECT kw.k, max(kw.half + kw.wall) AS reach FROM kw GROUP BY kw.k),
     -- the rivers that cut gorges (great rivers, rivers, streams) near the block, as pieces between their points, each
     -- kept when it comes within its own gorge's reach of the block
     -- the rivers that cut gorges (great rivers, rivers, streams) near the block, as straight pieces between every
     -- fourth point of their line (a square apart on the battle grid; four squares strays from the line by well under a
     -- square, nothing beside a wall tens of squares wide), each kept when it comes within its own gorge's reach of the block
     pt AS (SELECT r.pid, r.k, r.t, r.x, r.y, row_number() OVER (PARTITION BY r.pid ORDER BY r.t) AS rn, count(*) OVER (PARTITION BY r.pid) AS n
              FROM (SELECT max(kr.reach) + 1 AS reach FROM kr HAVING count(*) > 0) m
             CROSS JOIN LATERAL public.rpg_map_river_line(7, 1, p_x0::double precision, p_y0::double precision,
                                                          (p_x0 + p_cols)::double precision, (p_y0 + p_rows)::double precision,
                                                          greatest(m.reach, 180), 4) r),
     rl AS MATERIALIZED (
       SELECT q.* FROM (
         SELECT pt.k, pt.x AS x0, pt.y AS y0, lead(pt.x) OVER w AS x1, lead(pt.y) OVER w AS y1
           FROM pt WHERE mod(pt.rn - 1, 4) = 0 OR pt.rn = pt.n
         WINDOW w AS (PARTITION BY pt.pid ORDER BY pt.t)) q
        JOIN kr ON kr.k = q.k
        WHERE q.x1 IS NOT NULL
          AND greatest(q.x0, q.x1) >= p_x0 - kr.reach AND least(q.x0, q.x1) <= p_x0 + p_cols + kr.reach
          AND greatest(q.y0, q.y1) >= p_y0 - kr.reach AND least(q.y0, q.y1) <= p_y0 + p_rows + kr.reach),
     sq AS (SELECT gx.x, gy.y FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy(y)
             WHERE EXISTS (SELECT 1 FROM rl)),
     -- each square and how near each size of river comes to its middle
     nd AS (SELECT sq.x, sq.y, rl.k, min(n.d) AS d
              FROM sq JOIN kr ON true
              JOIN rl ON rl.k = kr.k
                     AND sq.x + 0.5 BETWEEN least(rl.x0, rl.x1) - kr.reach AND greatest(rl.x0, rl.x1) + kr.reach
                     AND sq.y + 0.5 BETWEEN least(rl.y0, rl.y1) - kr.reach AND greatest(rl.y0, rl.y1) + kr.reach
             CROSS JOIN LATERAL public.rpg_seg_nearest(sq.x + 0.5, sq.y + 0.5, rl.x0, rl.y0, rl.x1, rl.y1) n
             GROUP BY sq.x, sq.y, rl.k),
     -- the gorge wall a square is on each ground: the deepest gorge it is inside the rim of (a square under the river is
     -- water, not hills or mountains, so is never climbed)
     gw AS (SELECT nd.x, nd.y, kw.kind, kw.angle, nd.k, kw.depth
              FROM nd JOIN kw ON kw.k = nd.k WHERE nd.d < kw.half + kw.wall),
     gm AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'mountains' ORDER BY gw.x, gw.y, gw.depth DESC),
     gh AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'hills' ORDER BY gw.x, gw.y, gw.depth DESC),
     -- (walk speed step) only the squares steep enough to be a cliff (the top map_cliff_share) are given their angle
     mc AS (SELECT s.x, s.y, a.angle FROM public.rpg_map_steep(p_level, p_x0, p_y0, p_cols, p_rows) s
             CROSS JOIN LATERAL (SELECT public.rpg_map_cliff_angle(s.steep) AS angle) a
             WHERE p_level = 7 AND s.steep >= 1 - (SELECT st2.value FROM public.rpg_settings st2
                                                   WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_cliff_share')
               AND a.angle IS NOT NULL),
     al AS (SELECT gm.x, gm.y FROM gm UNION SELECT gh.x, gh.y FROM gh UNION SELECT mc.x, mc.y FROM mc)
SELECT al.x, al.y, greatest(gm.angle, mc.angle), gh.angle,
       CASE WHEN gm.angle >= coalesce(mc.angle, 0) THEN gm.k ELSE gh.k END
  FROM al LEFT JOIN gm ON gm.x = al.x AND gm.y = al.y LEFT JOIN gh ON gh.x = al.x AND gh.y = al.y
  LEFT JOIN mc ON mc.x = al.x AND mc.y = al.y;
$function$
;
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
--   a cliff is climbed (step 7c; canyons 2026-10-09): on the battle grid each cliff square (rpg_map_cliffs: a mountain cliff or a gorge wall)
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
-- Weather (weather step 2a) adds its percent of time to each square walked, read where and when the square is reached,
-- and (step 2a2) each leg of the trail keeps the shortest sight of the weather met on it.
-- The time walked plus any camp is the turn (turn_move_ticks), and the turn passes on (rpg_session_next_turn).
-- Pieces stand on world squares counted from 1 (pos_x = square + 1), like squares on a fight board. A piece under the
-- ground (step 12d2) walks its passages instead (rpg_map_under_walk).
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
  v_hour integer; v_d100 integer; v_new integer[]; v_cell bigint; v_wd double precision; v_wl integer; v_deep integer[]; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid;
  v_wc double precision; v_swim boolean; v_dif numeric; v_rtk integer; v_breath integer; v_drown integer; v_lost numeric; v_need2 numeric;
  v_sw_in boolean := false; v_sw_clock numeric := 0; v_sw_next numeric := 0; v_sw_under integer := 0; v_sw_long integer := 0; v_sw_dips integer := 0;
  v_sw_rolls integer := 0; v_sw_points numeric := 0; v_sw_harmt integer := 0; v_sw_harm integer := 0; v_sw_key text; v_sw_skill numeric; v_sw_gear boolean;
  v_sw_breathes boolean; v_sw_left integer; v_sw_max integer; v_sw_maxdif numeric := 0; v_sw_val numeric;
  v_cliff double precision; v_cl_rise double precision; v_cl_dif numeric; v_cl_key text; v_cl_skill numeric; v_cl_gear boolean;
  v_cl_rolls integer := 0; v_cl_points numeric := 0; v_cl_falls integer := 0; v_cl_harm integer := 0; v_cl_count integer := 0; v_cl_maxdif numeric := 0;
  v_cl_n integer; v_cl_extra numeric; v_cl_try bigint; v_cl_left integer; v_cl_max integer; v_fixed bigint := 0; j integer;
  v_wx integer[]; v_wy integer[]; v_wk integer[]; v_wp uuid[]; v_stop boolean; v_cum integer[]; v_lk integer; v_kind text; v_place uuid;
  v_onroad integer := 0; v_ex integer; v_ey integer; v_house boolean := false; v_nx integer; v_ny integer;
  v_clock0 bigint; v_wthr jsonb; v_wthr_pct integer := 0; v_wthr_names text[] := '{}'; v_rs bigint[] := '{}'; v_lsight bigint;
  v_clf jsonb := '{}'; v_clf_done text[] := '{}'; v_clf_b text; v_cbx0 integer; v_cby0 integer; v_cbx1 integer; v_cby1 integer;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  -- (storeys step) up a house, the way out is down its stair first (rpg_act_stair)
  IF v_p.floor > 0 THEN RAISE EXCEPTION '% is upstairs: come down the stair first', v_p.name; END IF;
  IF v_p.floor < 0 THEN RAISE EXCEPTION '% is down in a cellar: come up the stair first', v_p.name; END IF;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  IF v_p.under_at IS NOT NULL THEN RAISE EXCEPTION '% is under the ground: walk its passages, or come up at the mouth of a cave or a mine', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_world OR p_y NOT BETWEEN 1 AND v_down THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1; v_gx := p_x - 1; v_gy := p_y - 1;
  v_haunt := v_p.haunt_ticks;
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
  -- (weather step 2a) the journey clock as the walk sets out: the weather of each stretch is read at the time it is reached
  SELECT s.clock INTO v_clock0 FROM public.rpg_sessions s WHERE s.id = v_sid;
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
      -- a cliff on the battle grid: climbed, at the time its climb takes; a mountain cliff or the wall of a gorge where a
      -- river cuts through hills or mountains (rpg_map_cliffs; canyons, Peter 2026-10-09), read 32 by 32 squares at a
      -- time and kept for the rest of the walk
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_kind IN ('mountains', 'hills') AND v_r.level = 7 THEN
        -- (walk speed step) the first time, the whole box from the start to the target and 8 squares round it in one
        -- read; a square outside it reads its block of 32 by 32
        IF v_cbx0 IS NULL THEN
          v_cbx0 := -1; v_cby0 := -1; v_cbx1 := -2; v_cby1 := -2;
          IF abs(v_gx - v_sx) <= 144 AND abs(v_gy - v_sy) <= 144 THEN
            v_cbx0 := greatest(least(v_sx, v_gx) - 8, 0); v_cby0 := greatest(least(v_sy, v_gy) - 8, 0);
            v_cbx1 := greatest(v_sx, v_gx) + 8; v_cby1 := greatest(v_sy, v_gy) + 8;
            v_clf := coalesce((SELECT jsonb_object_agg(t.x || ',' || t.y, jsonb_build_array(t.mountains, t.hills))
                                 FROM public.rpg_map_cliffs(7, v_cbx0, v_cby0, v_cbx1 - v_cbx0 + 1, v_cby1 - v_cby0 + 1) t), '{}');
          END IF;
        END IF;
        v_clf_b := ((v_hx - 1) / 32) || ',' || ((v_hy - 1) / 32);
        IF NOT (v_hx - 1 BETWEEN v_cbx0 AND v_cbx1 AND v_hy - 1 BETWEEN v_cby0 AND v_cby1) AND NOT (v_clf_b = ANY (v_clf_done)) THEN
          v_clf := v_clf || coalesce((SELECT jsonb_object_agg(t.x || ',' || t.y, jsonb_build_array(t.mountains, t.hills))
                                        FROM public.rpg_map_cliffs(7, ((v_hx - 1) / 32) * 32, ((v_hy - 1) / 32) * 32, 32, 32) t), '{}');
          v_clf_done := v_clf_done || v_clf_b;
        END IF;
        v_cliff := (v_clf -> ((v_hx - 1) || ',' || (v_hy - 1)) ->> CASE WHEN v_kind = 'mountains' THEN 0 ELSE 1 END)::double precision;
        IF v_cliff IS NOT NULL THEN SELECT m.pct, m.rise, m.difficulty INTO v_pen, v_cl_rise, v_cl_dif FROM public.rpg_map_climb(v_cliff) m; END IF;
      END IF;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      -- (weather step 2a) the weather over the stretch when it is reached (rpg_map_weather_here) adds its percent of time to
      -- every square on top of the ground: rain +10%, snow +30%, a blizzard +100% (rpg_map_weathers); not to swimming or
      -- a cliff, whose time is their own
      v_wthr_pct := 0;
      -- (weather step 2a2) the weather also sets how far the walker sees along this stretch (its sight, kept with the trail)
      v_wthr := public.rpg_map_weather_here(v_hx - 1, v_hy - 1, v_clock0 + public.rpg_ticks_at(v_speed, v_base / 100.0));
      IF NOT v_swim AND v_cliff IS NULL THEN
        v_wthr_pct := coalesce((v_wthr->>'walk_pct')::integer, 0);
        IF v_wthr_pct > 0 AND NOT (lower(v_wthr->>'name') = ANY (v_wthr_names)) THEN v_wthr_names := v_wthr_names || lower(v_wthr->>'name'); END IF;
      END IF;
      v_b := v_mt * (100 + CASE WHEN v_ign THEN 0 ELSE v_pen END + v_wthr_pct);
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
          -- the hourly rolls (rpg_map_meet_roll)
          SELECT r.rolls, r.hour INTO v_new, v_hour FROM public.rpg_map_meet_roll(v_h0, v_haunt) r;
          v_rolls := v_rolls || v_new;
          IF v_hour IS NOT NULL THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) * 100 / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0) - v_t0;
              v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
              v_why := 'meet';
          END IF;
        END IF;
      END IF;
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b; v_rs := v_rs || (v_wthr->>'sight')::bigint;
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
         -- the houses there (step 8c), only where a village, town, city or place is, and the landmarks (step 12b2)
         hs AS MATERIALIZED (SELECT b.x, b.y FROM bb CROSS JOIN LATERAL public.rpg_map_building_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) b
                              WHERE EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                 OR EXISTS (SELECT 1 FROM bb b2 CROSS JOIN LATERAL public.rpg_map_landmark_cells(7, b2.x0, b2.y0, b2.x1 - b2.x0 + 1, b2.y1 - b2.y0 + 1) m))
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
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone, a house or a landmark is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_path_at(v_wx, v_wy, v_k) s; END IF;
  -- the end square on the road itself (step 10b): the way along a road is a chain of points 216 squares or so apart
  -- (rpg_map_road_path), so a walk that ends on a leg along a road moves its last square to the nearest square of the
  -- road (rpg_map_road_snap) when that square is dry land (rpg_map_heights), not a river too deep to wade
  -- (rpg_map_flow), not a house and free
  IF v_k > 0 AND coalesce(v_why, '') <> 'drown' THEN
    SELECT v_wk[g.l + 1] INTO v_lk FROM generate_series(1, cardinality(v_wx) - 1) AS g(l) WHERE v_cum[g.l] < v_k AND v_k <= v_cum[g.l + 1] ORDER BY g.l LIMIT 1;
    IF v_lk BETWEEN 1 AND 3 THEN
      SELECT mod(s.x + v_world, v_world)::integer, s.y INTO v_nx, v_ny FROM public.rpg_map_road_snap(v_tx, v_ty) s;
      IF v_nx IS NOT NULL AND (v_nx <> v_tx OR v_ny <> v_ty)
         AND (SELECT h.height FROM public.rpg_map_heights(7, v_nx, v_ny, 1, 1) h) >= public.rpg_setting('map_sea_level')
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_flow(7, v_nx, v_ny, 1, 1) f WHERE f.depth >= public.rpg_setting('map_swim_depth'))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_building_cells(7, v_nx, v_ny, 1, 1))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                          WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = v_nx + 1 AND o.pos_y = v_ny + 1
                            AND public.rpg_participant_blocks(o.id)) THEN
        v_tx := v_nx; v_ty := v_ny;
      END IF;
    END IF;
  END IF;
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
  -- a stretch a leg of the way, as far as it was walked; and how many runs of those legs were on a road (a road is
  -- walked as a chain of legs, step 10b: one run from where the walk joins it to where it leaves)
  FOR i IN 1 .. cardinality(v_wx) - 1 LOOP
    EXIT WHEN v_cum[i] >= v_k;
    IF v_cum[i + 1] <= v_k THEN v_ex := v_wx[i + 1]; v_ey := v_wy[i + 1]; ELSE v_ex := v_tx; v_ey := v_ty; END IF;
    -- (weather step 2a2) the shortest sight of the weather met along this leg, none when it was all clear
    SELECT min(v_rs[g]) INTO v_lsight FROM generate_subscripts(v_rf, 1) AS g(g)
     WHERE v_rt[g] >= v_rf[g] AND v_rf[g] <= least(v_cum[i + 1], v_k) AND v_rt[g] >= v_cum[i] + 1;
    PERFORM public.rpg_map_trail_add(v_p.character_id, v_wx[i] + 1, v_wy[i] + 1, v_ex + 1, v_ey + 1, v_lsight);
    IF v_wk[i + 1] IS NOT NULL AND (i = 1 OR v_wk[i] IS NULL) THEN v_onroad := v_onroad + 1; END IF;
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
         || CASE WHEN v_house THEN ' A house or a landmark stands where the walk was heading: it stops in front of it.' ELSE '' END
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
         || CASE WHEN cardinality(v_wthr_names) > 0 THEN ' Slower going in the ' || array_to_string(v_wthr_names, ' and the ') || '.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text((SELECT l.steps FROM public.rpg_map_line(v_tx, v_ty, v_gx, v_gy) l)) || ' to go.' ELSE '' END;
  -- a creature met (rpg_map_meet): it joins and the fight is on; the rolls in words (rpg_map_meet_words)
  IF v_why = 'meet' THEN
    v_text := v_text || public.rpg_map_meet_words(v_rolls, true) || ' ' || public.rpg_map_meet(p_participant_id, v_meet, v_walk, v_tx + 1, v_ty + 1);
  ELSE
    v_text := v_text || public.rpg_map_meet_words(v_rolls, false);
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.rpg_map_views_at(p_x bigint, p_y bigint)
 RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $fn$
-- The maps of the Maps tab over one world square (p_x, p_y counted from 1, as pieces stand), as the tab names them: its
-- Region grid, City grid and District grid (walk speed step, 2026-10-09; the one home of it, read by the hourly
-- save-ahead for the pieces of the journey and by rpg_map_walk_prepare).
SELECT ARRAY['4-' || floor((p_x - 1) / 20736.0)::bigint || '-' || floor((p_y - 1) / 20736.0)::bigint,
             '5-' || floor((p_x - 1) / 1728.0)::bigint || '-' || floor((p_y - 1) / 1728.0)::bigint,
             '6-' || floor((p_x - 1) / 144.0)::bigint || '-' || floor((p_y - 1) / 144.0)::bigint];
$fn$;
REVOKE ALL ON FUNCTION public.rpg_map_views_at(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_views_at(bigint, bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_views_prepare_run(p_views text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Works out several maps of the Maps tab in the background, one after the other (rpg_map_view_prepare_run each), so
-- they never run at once and wait on each other. Called only through the service login by rpg_map_prepare_send.
DECLARE v text; v_n integer := 0;
BEGIN
  FOR v IN SELECT DISTINCT u FROM unnest(p_views) AS u LOOP
    PERFORM public.rpg_map_view_prepare_run(v);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('done', v_n);
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_map_views_prepare_run(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_views_prepare_run(text[]) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_prepare_send(p_views text[])
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Sends maps of the Maps tab to be worked out in the background (rpg_map_views_prepare_run, through the service login,
-- past the 8 seconds a login may run): the one home of that sending, for a map that timed out (rpg_map_view_prepare)
-- and a walk that timed out (rpg_map_walk_prepare). Returns at once; false when the service key is missing.
DECLARE v_key text;
BEGIN
  SELECT s.setting_value INTO v_key FROM public.settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = 'supabase_service_role_key';
  IF v_key IS NULL THEN RETURN false; END IF;
  PERFORM net.http_post(
    url := 'https://vulhdujhbwvibbojiimi.supabase.co/rest/v1/rpc/rpg_map_views_prepare_run',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('p_views', to_jsonb(p_views)),
    timeout_milliseconds := 180000);
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_map_prepare_send(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_prepare_send(text[]) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_view_prepare(p_view text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Asks for one map of the Maps tab to be worked out in the background (rpg_map_prepare_send), for a map whose read ran
-- past the time a login may take (speed step 1, 2026-10-09). The Maps tab calls it when a read times out, then asks
-- for the map again every few seconds; returns at once.
BEGIN
  PERFORM public.require_login('family');
  IF NOT (coalesce(p_view, '') = '' OR p_view ~ '^[0-9]+-[0-9]+-[0-9]+$' OR p_view ~ '^p-[0-9a-f-]{36}$' OR p_view ~ '^s-[0-9]+-[0-9]+$') THEN
    RAISE EXCEPTION 'that is not a map';
  END IF;
  RETURN jsonb_build_object('ok', public.rpg_map_prepare_send(ARRAY[coalesce(p_view, '')]));
END $fn$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk_prepare(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Asks for the ground of a walk to be worked out in the background (walk speed step, 2026-10-09): the Region, City and
-- District grids where the piece stands and where it is going (rpg_map_views_at), read one after the other
-- (rpg_map_prepare_send), so the rivers there are saved and the walk fits in the time a login may take. The Maps tab
-- calls it when a walk times out, then tries the walk again every few seconds; returns at once.
DECLARE v_p record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RAISE EXCEPTION 'that piece is not on the map'; END IF;
  RETURN jsonb_build_object('ok', public.rpg_map_prepare_send(
    public.rpg_map_views_at(v_p.pos_x, v_p.pos_y) || CASE WHEN p_x IS NULL OR p_y IS NULL THEN '{}'::text[] ELSE public.rpg_map_views_at(p_x, p_y) END));
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_map_walk_prepare(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_walk_prepare(uuid, integer, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_warm_run(p_kind text, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Saves the map ahead, in the background (speed step 3, Peter 2026-10-09: save ahead so no map is worked out in a click):
--  * p_kind 'water': up to p_limit Country grids not saved yet that lie next to big water: the Country grid inside every
--    Continent cell of land with the sea, a lake or deep water beside it (eight round), and inside every Continent cell
--    of deep water (the great lakes), so the roads can tell where the water is from the saved map (rpg_map_wet_at);
--    about 1,640 grids, about 2 seconds each (rpg_map_cache_fill), nearest the group first;
--  * p_kind 'party': the Region, City and District grids under every piece of the open journey, read as the Maps tab
--    reads them (rpg_map_view_prepare_run), so the maps round the group are drawn and their rivers and roads kept
--    before anyone opens them.
-- Called through the service login by dispatch_rpg_map_warm (the hourly recipe Roleplaying map save-ahead).
DECLARE r record; v_n integer := 0; v_px double precision; v_py double precision; v_t0 timestamptz := clock_timestamp();
BEGIN
  IF p_kind = 'water' THEN
    SELECT avg(p.pos_x), avg(p.pos_y) INTO v_px, v_py
      FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE s.on_map AND s.status <> 'ended' AND p.pos_x IS NOT NULL AND p.creature_id IS NULL;
    FOR r IN
      WITH k AS MATERIALIZED (SELECT c.x, c.y, c.kind FROM public.rpg_map_cells(2, 0, 0, 144, 72) c)
      SELECT k.x, k.y FROM k
       WHERE (k.kind = 'deep'
              OR (k.kind NOT IN ('sea', 'deep', 'water')
                  AND EXISTS (SELECT 1 FROM k n WHERE n.kind IN ('sea', 'deep', 'water') AND abs(n.y - k.y) <= 1
                                                  AND (abs(n.x - k.x) <= 1 OR abs(n.x - k.x) = 143))))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = 3 AND m.gx = k.x AND m.gy = k.y)
       ORDER BY CASE WHEN v_px IS NULL THEN 0
                     ELSE power(least(abs((k.x + 0.5) * 248832 - v_px), 35831808 - abs((k.x + 0.5) * 248832 - v_px)), 2) + power((k.y + 0.5) * 248832 - v_py, 2) END,
                k.y, k.x
       LIMIT greatest(coalesce(p_limit, 0), 0)
    LOOP
      v_n := v_n + public.rpg_map_cache_fill(3, r.x * 12, r.y * 12, 12, 12);
    END LOOP;
  ELSIF p_kind = 'party' THEN
    FOR r IN
      SELECT DISTINCT v.view
        FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id
       CROSS JOIN LATERAL unnest(public.rpg_map_views_at(p.pos_x, p.pos_y)) AS v(view)
       WHERE s.on_map AND s.status <> 'ended' AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND p.under_at IS NULL
       LIMIT greatest(coalesce(p_limit, 0), 0)
    LOOP
      PERFORM public.rpg_map_view_prepare_run(r.view);
      v_n := v_n + 1;
    END LOOP;
  ELSE
    RAISE EXCEPTION 'unknown save-ahead kind %', p_kind;
  END IF;
  RETURN jsonb_build_object('kind', p_kind, 'done', v_n, 'seconds', round(extract(epoch FROM clock_timestamp() - v_t0)));
END $function$
;
-- (one quote mark to balance the text above for the SQL tool) '

