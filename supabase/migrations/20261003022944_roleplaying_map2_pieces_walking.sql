-- roleplaying_map2_pieces_walking: world map step 2 (Peter 2026-10-03, "Defaults" = 1B walking time, 2A no sea).
-- A journey is a session played on the world map (on_map). Pieces are its characters, standing on world squares
-- counted from 1. They take turns on the same clock a fight uses and walk by the same rule. The clock goes bigint:
-- a world crossing is hundreds of millions of ticks.

ALTER TABLE public.rpg_sessions ALTER COLUMN clock TYPE bigint;
ALTER TABLE public.rpg_session_participants ALTER COLUMN next_tick TYPE bigint;
ALTER TABLE public.rpg_sessions ADD COLUMN IF NOT EXISTS on_map boolean NOT NULL DEFAULT false;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS walk_to_x integer;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS walk_to_y integer;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS day_walk_ticks integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.rpg_sessions.on_map IS 'A journey: played on the world map, positions are world squares counted from 1.';
COMMENT ON COLUMN public.rpg_session_participants.walk_to_x IS 'On a journey: the world square (from 0) the piece was heading for when its walking day ran out.';
COMMENT ON COLUMN public.rpg_session_participants.day_walk_ticks IS 'On a journey: ticks walked since the piece last camped (at most walk_day_hours).';

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'ticks_per_hour', 21600, 'Ticks in an hour of game time: a tick is 1/6 of a second (Peter 2026-10-03, 1B)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'walk_day_hours', 8, 'Hours a piece walks on the world map before it camps'),
  ('126794dd-25ff-47d2-a436-724499733365', 'camp_hours', 16, 'Hours a piece camps after its walking day'),
  ('126794dd-25ff-47d2-a436-724499733365', 'journey_start_hour', 8, 'Hour of day 1 a journey starts (8 = 8 in the morning)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_participant_ignores_penalty(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether movement penalties never slow this one: a creature whose card has a move trait that says so
-- (Forest-Bound Terror: the Bramblemaw steps into briars of penalty 2 for 1). The one home of that test, read by
-- rpg_grid_costs on a fight board and rpg_map_walk on the world map.
SELECT EXISTS (SELECT 1 FROM public.rpg_session_participants p
                 JOIN public.rpg_creature_actions a ON a.creature_id = p.creature_id
                WHERE p.id = p_participant_id AND a.kind = 'trait' AND a.effect->>'on' = 'move'
                  AND coalesce((a.effect->>'ignore_penalty')::boolean, false));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_ground(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(penalty integer, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What a cell of the world map costs to walk into, by its kind (rpg_map_cells): the one home of the movement
-- penalty of the map. A square costs 1 plus its penalty. Open land 0; forest map_forest_penalty (1, and it is
-- forest); hills map_hills_penalty (1); mountains map_mountain_penalty (2), so a mountain square costs 3; a place the
-- penalty and forest on its card. The sea has no penalty because nobody walks into it (Peter 2026-10-03, 2A).
SELECT CASE p_kind WHEN 'sea' THEN NULL
                   WHEN 'land' THEN 0
                   WHEN 'place' THEN (SELECT c.place_penalty FROM public.rpg_creatures c WHERE c.id = p_place)
                   ELSE (SELECT s.value::integer FROM public.rpg_settings s
                          WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                            AND s.key = CASE p_kind WHEN 'forest' THEN 'map_forest_penalty' WHEN 'hills' THEN 'map_hills_penalty'
                                                    WHEN 'mountains' THEN 'map_mountain_penalty' END) END,
       CASE p_kind WHEN 'forest' THEN true
                   WHEN 'place' THEN coalesce((SELECT c.place_forest FROM public.rpg_creatures c WHERE c.id = p_place), false)
                   ELSE false END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_time_text(p_clock bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The journey clock in words. A tick is 1/6 of a second (ticks_per_hour 21,600; Peter 2026-10-03, 1B) and a journey
-- starts on day 1 at journey_start_hour (8 in the morning). Clock 0 reads "Day 1, 8:00 am"; clock 144,000 (6 hours
-- 40 minutes) reads "Day 1, 2:40 pm"; clock 518,400 (a whole day) reads "Day 2, 8:00 am".
SELECT 'Day ' || (q.m / 1440 + 1)::text || ', '
       || (CASE WHEN (q.m % 1440) / 60 % 12 = 0 THEN 12 ELSE (q.m % 1440) / 60 % 12 END)::text || ':'
       || lpad((q.m % 60)::text, 2, '0') || CASE WHEN (q.m % 1440) / 60 < 12 THEN ' am' ELSE ' pm' END
  FROM (SELECT (greatest(coalesce(p_clock, 0), 0) * 60 / t.tph + t.start * 60)::bigint AS m
          FROM (SELECT max(s.value) FILTER (WHERE s.key = 'ticks_per_hour')::bigint AS tph,
                       max(s.value) FILTER (WHERE s.key = 'journey_start_hour')::bigint AS start
                  FROM public.rpg_settings s
                 WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('ticks_per_hour', 'journey_start_hour')) t) q;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_duration_text(p_ticks bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A span of game time in words (a tick is 1/6 of a second): 90 ticks read "15 seconds", 144,000 read "6 h 40 min",
-- 518,400 read "1 day", 345,600 read "16 h".
SELECT CASE WHEN q.s < 60 THEN q.s::text || CASE WHEN q.s = 1 THEN ' second' ELSE ' seconds' END
            ELSE concat_ws(' ', CASE WHEN q.s / 86400 > 0 THEN (q.s / 86400)::text || CASE WHEN q.s / 86400 = 1 THEN ' day' ELSE ' days' END END,
                                CASE WHEN q.s / 3600 % 24 > 0 THEN (q.s / 3600 % 24)::text || ' h' END,
                                CASE WHEN q.s / 60 % 60 > 0 THEN (q.s / 60 % 60)::text || ' min' END) END
  FROM (SELECT round(greatest(coalesce(p_ticks, 0), 0) * 3600.0 / s.value)::bigint AS s
          FROM public.rpg_settings s
         WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'ticks_per_hour') q;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_line(p_x0 integer, p_y0 integer, p_x1 integer, p_y1 integer)
 RETURNS TABLE(dx integer, dy integer, steps integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- The straight walk between two world squares (counted from 0, as on the place cards): the one home of how a walk
-- runs. A step goes one square straight or diagonally (a diagonal step costs the same as a straight one), so a walk
-- takes as many steps as the larger of its two gaps. East to west it goes the shorter way round (the map wraps), so
-- dx is never more than half the world. From 100, 50 to 103, 58: dx 3, dy 8, 8 steps.
SELECT d.dx, d.dy, greatest(abs(d.dx), abs(d.dy))
  FROM (SELECT (mod(p_x1::bigint - p_x0 + w.w + w.w / 2, w.w) - w.w / 2)::integer AS dx, p_y1 - p_y0 AS dy
          FROM (SELECT l.span::bigint AS w FROM public.rpg_map_ladder() l WHERE l.level = 1) w) d;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_line_at(p_x0 integer, p_y0 integer, p_x1 integer, p_y1 integer, p_k integer)
 RETURNS TABLE(x integer, y integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- The square a walk (rpg_map_line) is on after p_k steps: step 0 is the start, the last step the end. Each step moves
-- one square along the longer gap and the shorter gap is shared out evenly, rounded: from 100, 50 to 103, 58 step 4
-- is on 102, 54.
SELECT mod(p_x0 + CASE WHEN l.steps = 0 THEN 0 ELSE floor((2::numeric * p_k * l.dx + l.steps) / (2 * l.steps)) END::bigint + w.w, w.w)::integer,
       (p_y0 + CASE WHEN l.steps = 0 THEN 0 ELSE floor((2::numeric * p_k * l.dy + l.steps) / (2 * l.steps)) END)::integer
  FROM public.rpg_map_line(p_x0, p_y0, p_x1, p_y1) l
 CROSS JOIN (SELECT m.span::bigint AS w FROM public.rpg_map_ladder() m WHERE m.level = 1) w;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_route(p_x0 integer, p_y0 integer, p_x1 integer, p_y1 integer, p_max integer DEFAULT NULL::integer, p_from integer DEFAULT 1)
 RETURNS TABLE(k_from integer, k_to integer, kind text, place_id uuid, level integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground under a walk (rpg_map_line), read a stretch at a time and never square by square (20 miles is 28,779
-- squares). It covers the steps p_from to p_max (what the walking day can hold; a closer look at one stretch). The
-- ground is read on the finest grid of the ladder where those steps cross at most 72 cells: up to 72 squares on the battle grid itself, up to 864 squares
-- (0.6 mile) in 44-foot runs, up to 10,368 (7.2 miles) in 528-foot runs, past that in 1.2-mile runs. One row a run:
-- the steps k_from to k_to (step 1 is the first square entered) all in one cell of that grid, its kind and place as
-- rpg_map_cells gives them, and the grid read. The cells are asked for a block at a time (the walk where it crosses
-- one grid of the level above), never one by one.
WITH ln AS MATERIALIZED (
       SELECT l.dx::bigint AS dx, l.dy::bigint AS dy, l.steps, least(l.steps, greatest(coalesce(p_max, l.steps), 0)) AS k_end,
              greatest(coalesce(p_from, 1), 1) AS k0
         FROM public.rpg_map_line(p_x0, p_y0, p_x1, p_y1) l),
     lv AS MATERIALIZED (
       SELECT w.level, w.cell::bigint AS cell
         FROM public.rpg_map_ladder() w CROSS JOIN ln
        WHERE ln.k_end - ln.k0 + 1 <= 72::bigint * w.cell
        ORDER BY w.level DESC LIMIT 1),
     ax AS (SELECT p_x0::bigint AS a, ln.dx AS d,
                   p_x0 + floor((2::numeric * ln.k0 * ln.dx + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint AS b,
                   p_x0 + floor((2::numeric * ln.k_end * ln.dx + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint AS e FROM ln
            UNION ALL
            SELECT p_y0::bigint, ln.dy,
                   p_y0 + floor((2::numeric * ln.k0 * ln.dy + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint,
                   p_y0 + floor((2::numeric * ln.k_end * ln.dy + ln.steps) / (2 * greatest(ln.steps, 1)))::bigint FROM ln),
     bd AS (
       -- the first step in each new cell along one axis: p(k) = a + floor((2kd + S) / 2S) first reaches t = m x cell
       -- going up at k = ceil(S(2(t - a) - 1) / 2d), and first drops below t going down at floor(S(2(t - a) - 1) / 2d) + 1
       SELECT CASE WHEN ax.d > 0 THEN ceil(ln.steps::numeric * (2 * (m * lv.cell - ax.a) - 1) / (2 * ax.d))
                   ELSE floor(ln.steps::numeric * (2 * (m * lv.cell - ax.a) - 1) / (2 * ax.d)) + 1 END::bigint AS k
         FROM ax CROSS JOIN ln CROSS JOIN lv
        CROSS JOIN LATERAL generate_series(CASE WHEN ax.d > 0 THEN floor(ax.b::numeric / lv.cell)::bigint + 1 ELSE floor(ax.e::numeric / lv.cell)::bigint + 1 END,
                                           CASE WHEN ax.d > 0 THEN floor(ax.e::numeric / lv.cell)::bigint ELSE floor(ax.b::numeric / lv.cell)::bigint END) AS m
        WHERE ax.d <> 0),
     st AS (SELECT DISTINCT q.k FROM (SELECT ln.k0::bigint AS k FROM ln UNION ALL SELECT bd.k FROM bd) q CROSS JOIN ln WHERE q.k BETWEEN ln.k0 AND ln.k_end),
     rn AS (SELECT st.k AS k_from, coalesce(lead(st.k) OVER (ORDER BY st.k) - 1, ln.k_end) AS k_to FROM st CROSS JOIN ln),
     ce AS MATERIALIZED (
       SELECT rn.k_from::integer AS k_from, rn.k_to::integer AS k_to, (s.x / lv.cell)::integer AS cx, (s.y / lv.cell)::integer AS cy
         FROM rn CROSS JOIN lv CROSS JOIN LATERAL public.rpg_map_line_at(p_x0, p_y0, p_x1, p_y1, rn.k_from::integer) s),
     bl AS (SELECT min(ce.cx) AS x0, max(ce.cx) AS x1, min(ce.cy) AS y0, max(ce.cy) AS y1 FROM ce GROUP BY ce.cx / 12, ce.cy / 12),
     kd AS MATERIALIZED (
       SELECT c.x, c.y, c.kind, c.place_id
         FROM bl CROSS JOIN lv CROSS JOIN LATERAL public.rpg_map_cells(lv.level, bl.x0, bl.y0, bl.x1 - bl.x0 + 1, bl.y1 - bl.y0 + 1) c)
SELECT ce.k_from, ce.k_to, kd.kind, kd.place_id, lv.level
  FROM ce CROSS JOIN lv JOIN kd ON kd.x = ce.cx AND kd.y = ce.cy
 ORDER BY ce.k_from;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_turn(p_participant_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The checks every move on the world map makes first, in one place: the game master is playing, the piece is on a
-- journey (a session played on the world map), the journey has started and is not over, and it is the turn of this
-- piece. Locks the journey and returns its id.
DECLARE v_p record; v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master moves pieces on the map'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not on this journey'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF NOT v_s.on_map THEN RAISE EXCEPTION 'that is a fight, not a journey'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that journey is over'; END IF;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'start the journey first'; END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_participant_id THEN RAISE EXCEPTION 'it is not the turn of %', v_p.name; END IF;
  RETURN v_s.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece walks toward a world square (p_x, p_y counted from 0 at the north-west corner, as on the place cards) on
-- its turn, the whole way in one go: the same movement rule as a fight, at every level (Peter 2026-10-01). Every
-- square entered costs 1 plus its movement penalty (rpg_map_ground), move_ticks (5) a point at Speed 10, faster or
-- slower by Speed (rpg_ticks_at: base x 20 / (10 + Speed)). A tick is 1/6 of a second (Peter 2026-10-03, 1B), so open
-- land goes at about 3 miles an hour at Speed 10: 20 miles in 6 h 40 min.
-- The walk runs straight (rpg_map_line, ground from rpg_map_route, looked at closer where the sea starts) and stops:
--   at the shore: nobody walks into the sea (2A); the piece stands on the last dry square before it;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on.
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
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 0 AND v_world - 1 OR p_y NOT BETWEEN 0 AND v_down - 1 THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_mt := public.rpg_setting('move_ticks')::integer;
  v_even := public.rpg_setting('speed_even');
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  SELECT l.steps INTO v_steps FROM public.rpg_map_line(v_sx, v_sy, p_x, p_y) l;
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even))::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / v_mt)::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 40 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, p_x, p_y, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      SELECT g.penalty INTO v_pen FROM public.rpg_map_ground(v_r.kind, v_r.place_id) g;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (1 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer);
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b;
      v_base := v_base + v_n::bigint * v_b;
      v_reach := v_r.k_from + v_n - 1;
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
            CROSS JOIN LATERAL public.rpg_map_line_at(v_sx, v_sy, p_x, p_y, g.k) s),
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
  v_walk := public.rpg_ticks_at(v_speed, v_base);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR v_p.day_walk_ticks + v_walk >= v_day;
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea is in the way' ELSE 'someone is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_line_at(v_sx, v_sy, p_x, p_y, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day' THEN p_x END,
         walk_to_y = CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day' THEN p_y END
   WHERE id = p_participant_id;
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
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_camp(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece camps where it stands on its turn: camp_hours (16) pass for it and its walking day starts fresh (Peter
-- 2026-10-03, 1B: at most 8 hours of walking, then 16 of camp). The square it was heading for stays, so it can carry on.
DECLARE v_sid uuid; v_p record; v_camp integer; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  v_camp := public.rpg_setting('camp_hours')::integer * public.rpg_setting('ticks_per_hour')::integer;
  UPDATE public.rpg_session_participants SET day_walk_ticks = 0 WHERE id = p_participant_id;
  UPDATE public.rpg_sessions SET turn_move_ticks = v_camp, turn_action_ticks = 0, updated_at = now() WHERE id = v_sid;
  v_text := v_p.name || ' camps for ' || public.rpg_map_duration_text(v_camp) || '.';
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'camp', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  RETURN jsonb_build_object('text', v_text, 'next', public.rpg_session_next_turn(v_sid));
END;
$function$;

-- rpg_session_new gains p_on_map. No database function calls it (checked 2026-10-03); the page calls it by name with
-- p_name only, which the new signature still takes. The old one-argument version goes so the two cannot clash.
DROP FUNCTION IF EXISTS public.rpg_session_new(text);
CREATE OR REPLACE FUNCTION public.rpg_session_new(p_name text, p_on_map boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new fight, or with p_on_map a new journey: a session played on the world map, where pieces walk on their turns
-- (rpg_map_walk) on the same clock a fight uses. One journey is open at a time. It waits in setup while the game
-- master adds characters; the first turn starts it.
DECLARE v_id uuid; v_map boolean := coalesce(p_on_map, false);
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master starts a fight'; END IF;
  IF v_map AND EXISTS (SELECT 1 FROM public.rpg_sessions WHERE on_map AND status <> 'ended') THEN
    RAISE EXCEPTION 'a journey is already open';
  END IF;
  INSERT INTO public.rpg_sessions (name, on_map)
  VALUES (coalesce(nullif(btrim(p_name), ''), CASE WHEN v_map THEN 'Journey' ELSE 'Fight' END || ' on '
                   || to_char(now() AT TIME ZONE 'America/Chicago', 'FMMonth FMDD')), v_map)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.rpg_session_new(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_session_new(text, boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpg_map_walk(uuid, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_map_walk(uuid, integer, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpg_map_camp(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_map_camp(uuid) TO authenticated, service_role;

-- Changed in place, by exact replacements on the live definitions of 2026-10-03:

CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square of the board from where they stand. Stepping into a square costs
-- 1 + its movement penalty (just 1 for a creature whose card says penalties never slow it: Forest-Bound Terror), plus
-- burn_cost (3) while the square burns, for everyone; a diagonal step costs the same as a straight one; nobody steps
-- into a square someone takes up (rpg_participant_blocks). Squares nobody can get to are left out. From C3, briars of
-- penalty 2 on D3 cost 3 to enter, and E3 past them costs 4; burning briars cost 6, and the Bramblemaw pays 4 there.
DECLARE
  v_p record; v_s record; w integer; h integer; n integer; d integer[]; pen integer[]; fire integer[]; blk boolean[];
  v_ign boolean; v_changed boolean; v_big constant integer := 1000000; i integer; j integer; cx integer; cy integer;
  dx integer; dy integer; nx integer; ny integer; c integer; v_k text; v_v jsonb; v_o record; v_i record;
  v_burn integer := public.rpg_setting('burn_cost')::integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  w := v_s.grid_w; h := v_s.grid_h; n := w * h;
  IF v_p.pos_x > w OR v_p.pos_y > h THEN RETURN; END IF;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_k, v_v IN SELECT t.key, t.value FROM jsonb_each(v_s.terrain) t LOOP
    cx := split_part(v_k, ',', 1)::integer; cy := split_part(v_k, ',', 2)::integer;
    IF cx BETWEEN 1 AND w AND cy BETWEEN 1 AND h THEN
      SELECT * INTO v_i FROM public.rpg_square_info(v_v, v_s.round);
      pen[(cy - 1) * w + cx] := v_i.penalty;
      fire[(cy - 1) * w + cx] := CASE WHEN v_i.burning THEN v_burn ELSE 0 END;
    END IF;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND public.rpg_participant_blocks(o.id) LOOP
    IF v_o.pos_x BETWEEN 1 AND w AND v_o.pos_y BETWEEN 1 AND h THEN blk[(v_o.pos_y - 1) * w + v_o.pos_x] := true; END IF;
  END LOOP;
  d[(v_p.pos_y - 1) * w + v_p.pos_x] := 0;
  LOOP
    v_changed := false;
    FOR i IN 1..n LOOP
      CONTINUE WHEN d[i] >= v_big;
      cx := (i - 1) % w + 1; cy := (i - 1) / w + 1;
      FOR dx IN -1..1 LOOP
        FOR dy IN -1..1 LOOP
          nx := cx + dx; ny := cy + dy;
          CONTINUE WHEN (dx = 0 AND dy = 0) OR nx < 1 OR ny < 1 OR nx > w OR ny > h;
          j := (ny - 1) * w + nx;
          CONTINUE WHEN blk[j];
          c := d[i] + 1 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + fire[j];
          IF c < d[j] THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT (k - 1) % w + 1, (k - 1) / w + 1, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
-- Each cell also carries to = the world square at its middle (counted from 0), where a piece walks or is placed when
-- the cell is tapped. journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is) and the characters that can still join.
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
  v_journey   jsonb;
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
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || c.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(c.x::bigint * v_l.cell + v_l.cell / 2, c.y::bigint * v_l.cell + v_l.cell / 2)))
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
                      'id', p.id, 'name', p.name, 'color', ch.color, 'placed', p.pos_x IS NOT NULL,
                      'spot', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.sx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.sx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
                      'find', CASE WHEN p.pos_x IS NOT NULL AND v_l.level > 1 THEN v_l.level::text || '-' || (q.sx / v_l.span)::text || '-' || (q.sy / v_l.span)::text END,
                      'next', CASE WHEN s.status = 'active' AND p.id IS DISTINCT FROM s.current_participant_id AND p.next_tick IS NOT NULL
                                   THEN public.rpg_map_duration_text(greatest(p.next_tick - s.clock, 0)) END,
                      'day_left', public.rpg_map_duration_text(greatest(d.day - p.day_walk_ticks, 0)),
                      'walk_to', CASE WHEN p.walk_to_x IS NOT NULL THEN jsonb_build_array(p.walk_to_x, p.walk_to_y) END,
                      'to_go', CASE WHEN p.walk_to_x IS NOT NULL AND p.pos_x IS NOT NULL
                                    THEN public.rpg_map_length_text((SELECT w.steps FROM public.rpg_map_line(q.sx::integer, q.sy::integer, p.walk_to_x, p.walk_to_y) w)) END))
                    ORDER BY p.next_tick NULLS LAST, p.turn_order, p.created_at)
               FROM public.rpg_session_participants p
               LEFT JOIN public.rpg_characters ch ON ch.id = p.character_id
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id), '[]'::jsonb),
           'can_join', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb))
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', v_l.name, 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_l.cols, 'rows', v_l.rows, 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a fighter on a square, or with no square takes them off the board. Free, any time, but never
-- onto a square someone takes up. On a journey (on_map) the square is a world square counted from 0 as on the place
-- cards, stored counted from 1, and never sea; placing a piece forgets where it was heading.
DECLARE v_p record; v_s record; v_who text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL WHERE id = p_participant_id;
  ELSE
    IF v_s.on_map THEN
      IF p_x NOT BETWEEN 0 AND (SELECT l.span - 1 FROM public.rpg_map_ladder() l WHERE l.level = 1)
         OR p_y NOT BETWEEN 0 AND (SELECT l.span / 2 - 1 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
        RAISE EXCEPTION 'that square is off the map';
      END IF;
      IF (SELECT c.kind FROM public.rpg_map_cells(7, p_x, p_y, 1, 1) c) = 'sea' THEN RAISE EXCEPTION 'that square is sea'; END IF;
    ELSIF p_x NOT BETWEEN 1 AND v_s.grid_w OR p_y NOT BETWEEN 1 AND v_s.grid_h THEN RAISE EXCEPTION 'that square is off the board'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x + CASE WHEN v_s.on_map THEN 1 ELSE 0 END
       AND o.pos_y = p_y + CASE WHEN v_s.on_map THEN 1 ELSE 0 END AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on %', v_who, CASE WHEN v_s.on_map THEN 'that square' ELSE public.rpg_square_name(p_x, p_y) END; END IF;
    UPDATE public.rpg_session_participants
       SET pos_x = p_x + CASE WHEN v_s.on_map THEN 1 ELSE 0 END, pos_y = p_y + CASE WHEN v_s.on_map THEN 1 ELSE 0 END,
           walk_to_x = NULL, walk_to_y = NULL
     WHERE id = p_participant_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_add(p_session_id uuid, p_character_id uuid DEFAULT NULL::uuid, p_creature_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one character, or one creature made fresh from its card, to a fight at its Agility place: ahead of the first
-- one in line with lower Agility, so higher Agility acts first and a tie goes after whoever joined first; that order breaks ties on the fight
-- clock. Joining a fight already on, the first turn comes one beat from now (Speed 7: 12 ticks). A creature is made the way any character is made (rpg_new_character from its card, as a
-- non-player character), kept for this fight only (session_id) and left off the lists of players. So two Ashwing
-- Harriers are two different rolls (Physical Vitality 40 to 50), while a boss card like the Bramblemaw comes out the
-- same every time. The Bramblemaw (Agility 7) lands ahead of Karen (Agility 1). A second one is named "Bramblemaw 2".
DECLARE v_s record; v_name text; v_card uuid; v_leg integer := 0; v_n integer; v_id uuid; v_char uuid := p_character_id; v_ag numeric; v_pos integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master adds to a fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF (p_character_id IS NULL) = (p_creature_id IS NULL) THEN RAISE EXCEPTION 'add one character or one creature'; END IF;
  IF p_character_id IS NOT NULL THEN
    SELECT name INTO v_name FROM public.rpg_characters WHERE id = p_character_id AND is_active AND session_id IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
    IF EXISTS (SELECT 1 FROM public.rpg_session_participants WHERE session_id = p_session_id AND character_id = p_character_id) THEN
      RAISE EXCEPTION '% is already in this fight', v_name;
    END IF;
  ELSE
    SELECT name, id, legendary_per_round INTO v_name, v_card, v_leg FROM public.rpg_creatures WHERE id = p_creature_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'creature not found'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.rpg_creature_actions WHERE creature_id = p_creature_id AND kind <> 'trait') THEN
      RAISE EXCEPTION '% has nothing on its card to fight with', v_name;
    END IF;
    SELECT count(*) INTO v_n FROM public.rpg_session_participants WHERE session_id = p_session_id AND creature_id = p_creature_id;
    IF v_n > 0 THEN v_name := v_name || ' ' || (v_n + 1); END IF;
    v_char := public.rpg_new_character(v_name, NULL, true, v_card);
    UPDATE public.rpg_characters SET session_id = p_session_id WHERE id = v_char;
  END IF;
  INSERT INTO public.rpg_session_participants (agency_id, session_id, character_id, creature_id, name, legendary_left)
  VALUES (v_s.agency_id, p_session_id, v_char, p_creature_id, v_name, coalesce(v_leg, 0))
  RETURNING id INTO v_id;
  v_ag := coalesce(public.rpg_participant_value(v_id, 'AG'), 0);
  SELECT min(p.turn_order) INTO v_pos FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.id <> v_id AND coalesce(public.rpg_participant_value(p.id, 'AG'), 0) < v_ag;
  IF v_pos IS NULL THEN
    SELECT coalesce(max(turn_order), 0) + 1 INTO v_pos
      FROM public.rpg_session_participants WHERE session_id = p_session_id AND id <> v_id;
  ELSE
    UPDATE public.rpg_session_participants SET turn_order = turn_order + 1
     WHERE session_id = p_session_id AND id <> v_id AND turn_order >= v_pos;
  END IF;
  UPDATE public.rpg_session_participants SET turn_order = v_pos WHERE id = v_id;
  IF v_s.status = 'active' THEN
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + public.rpg_action_ticks(v_id, 1) WHERE id = v_id;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_s.round, 'join', v_id, v_name || CASE WHEN v_s.on_map THEN ' joins the journey (Agility ' ELSE ' joins the fight (Agility ' END || trim_scale(v_ag) || ').');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The fights for the Play tab: open ones first, newest on top, then the last ten that are over. Journeys (played on
-- the world map) are on the Maps tab, not here.
SELECT public.require_login('family');
SELECT CASE WHEN NOT public.rpg_can_play() THEN '[]'::jsonb ELSE coalesce((
  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', s.status, 'round', s.round,
                     'updated_at', s.updated_at,
                     'who', (SELECT string_agg(p.name, ', ' ORDER BY p.turn_order, p.created_at)
                               FROM public.rpg_session_participants p WHERE p.session_id = s.id))
                   ORDER BY (s.status = 'ended'), s.updated_at DESC)
    FROM public.rpg_sessions s
   WHERE NOT s.on_map
     AND (s.status <> 'ended'
          OR s.id IN (SELECT e.id FROM public.rpg_sessions e WHERE e.status = 'ended' AND NOT e.on_map ORDER BY e.ended_at DESC NULLS LAST LIMIT 10))
), '[]'::jsonb) END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one on the fight clock. The turn's time is charged to the one who took it:
-- moving and acting together cost the bigger plus half the smaller (rpg_turn_cost: Zaboo walks 13 ticks and swings 27,
-- 27 + 6 = 33), or one beat of waiting when they did neither. Then whoever is next on the clock goes, the faster one on
-- a tie (Speed), then the Agility order they joined in (turn_order), so a quick fighter can act twice before a slow one
-- acts once (the Bramblemaw claws every 12 ticks, Karen swings every 36). In setup this starts the fight: everyone's
-- first turn comes one beat in (Speed 7: tick 12; Speed 1: tick 18). A new round begins every round_ticks (20): it
-- frees anyone Held from an earlier round, raises a creature whose revival wait is over (the Bramblemaw: Sunk in round
-- 5, rises with 1 when round 7 begins), gives everyone their energy regain once for each round passed, and gives
-- creatures back their legendary actions (Bramblemaw: 3). As a turn ends, every other creature with legendary actions
-- left rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one swipe at the character it scores highest on; Rootstep: a step toward the nearest character). At the start
-- of someone's turn they get up from Knocked down, what they put on others until then (clear 'source_turn': Judged)
-- comes off, and a check they tried on an earlier turn (Frightened) is due again. A creature out of the fight (dead,
-- or waiting under its card's revival rule: rpg_participant_out) gets no turn. The game master can pass any turn; a
-- player can end a character's turn, never a creature's.
DECLARE
  v_s record; v_cur record; v_next_id uuid; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric; v_cost integer; v_mv integer; v_ac integer;
  v_rt integer := public.rpg_setting('round_ticks')::integer; v_clock bigint; v_round integer; v_rounds integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT * INTO v_cur FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur.id IS NULL OR v_cur.creature_id IS NOT NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;
  PERFORM set_config('rpg.engine', 'on', true);

  IF v_s.status = 'active' AND v_cur.id IS NOT NULL THEN
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur.id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      v_best := NULL; v_top := 0;
      FOR v_la IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                   WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
                     AND public.rpg_action_ready(v_a.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_a.id, v_la.id, v_tg);
        IF (v_pick->>'score')::numeric > v_top THEN
          v_top := (v_pick->>'score')::numeric;
          v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets', 'square', v_pick->'square');
        END IF;
      END LOOP;
      CONTINUE WHEN v_best IS NULL;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || (v_best->>'name') || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        IF jsonb_typeof(v_best->'square') = 'object' THEN
          PERFORM public.rpg_act_square(v_a.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
        ELSE
          PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
        END IF;
      END IF;
    END LOOP;
    SELECT turn_move_ticks, turn_action_ticks INTO v_mv, v_ac FROM public.rpg_sessions WHERE id = p_session_id;
    v_cost := public.rpg_turn_cost(v_mv, v_ac);
    IF v_cost = 0 THEN v_cost := public.rpg_action_ticks(v_cur.id, 1); END IF;
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + v_cost WHERE id = v_cur.id;
  ELSIF v_s.status = 'setup' THEN
    UPDATE public.rpg_session_participants SET next_tick = public.rpg_action_ticks(id, 1) WHERE session_id = p_session_id;
  END IF;

  SELECT p.id INTO v_next_id FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND NOT public.rpg_participant_out(p.id)
   ORDER BY coalesce(p.next_tick, v_s.clock), public.rpg_participant_speed(p.id) DESC, p.turn_order, p.created_at LIMIT 1;
  IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  v_clock := greatest(coalesce(v_next.next_tick, v_s.clock), v_s.clock);
  IF v_s.status = 'setup' THEN
    v_round := 1;
  ELSE
    v_round := greatest(v_clock / v_rt + 1, v_s.round);
    v_rounds := v_round - v_s.round;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, clock = v_clock, current_participant_id = v_next_id,
         turn_move_ticks = 0, turn_action_ticks = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'info', CASE WHEN v_s.on_map THEN 'The journey begins.' ELSE 'The fight begins. Round 1.' END);
  ELSIF v_rounds > 0 THEN
    -- a journey passes thousands of rounds a walk: everything a round brings still happens, without a line in the log
    IF NOT v_s.on_map THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'round', 'info', 'Round ' || v_round || ' begins.');
    END IF;
    FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'round' AND (e->>'round')::integer < v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
       WHERE p.id = v_a.id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
    END LOOP;
    FOR v_a IN SELECT p.id, p.name, p.character_id, e AS eff FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'revive' AND (e->>'until_round')::integer <= v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
       WHERE p.id = v_a.id;
      UPDATE public.rpg_characters c
         SET vitality_damage = greatest((public.rpg_participant_vitality(v_a.id)->>'max')::integer - coalesce((v_a.eff->>'revive')::integer, 1), 0)
       WHERE c.id = v_a.character_id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id,
              v_a.name || ' rises with ' || coalesce((v_a.eff->>'revive')::integer, 1) || ' vitality.');
    END LOOP;
    UPDATE public.rpg_session_participants
       SET energy_used_physical = greatest(energy_used_physical - v_rounds * coalesce(public.rpg_participant_value(id, 'PER'), 0)::integer, 0),
           energy_used_spiritual = greatest(energy_used_spiritual - v_rounds * coalesce(public.rpg_participant_value(id, 'SER'), 0)::integer, 0),
           legendary_left = CASE WHEN creature_id IS NOT NULL
                                 THEN coalesce((SELECT c.legendary_per_round FROM public.rpg_creatures c WHERE c.id = creature_id), 0)
                                 ELSE legendary_left END
     WHERE session_id = p_session_id;
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename, coalesce((e->>'cannot_act')::boolean, false) AS held FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || CASE WHEN v_a.held THEN ' gets up. No longer ' ELSE ' is no longer ' END || v_a.ename || '.');
  END LOOP;
  UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e - 'checked_round'), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e)
   WHERE p.id = v_next_id AND EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) e WHERE e ? 'checked_round');
  FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
              WHERE p.session_id = p_session_id AND e->>'clear' = 'source_turn' AND e->>'source_id' = v_next_id::text LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' <> v_a.ename)
     WHERE p.id = v_a.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
  END LOOP;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'clock', v_clock, 'current_participant_id', v_next_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_end(p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master ends a fight. It stays in the list with its log, and nothing more can happen in it.
DECLARE v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master ends a fight'; END IF;
  UPDATE public.rpg_sessions SET status = 'ended', ended_at = now(), current_participant_id = NULL, updated_at = now()
   WHERE id = p_session_id AND status <> 'ended'
  RETURNING * INTO v_s;
  IF FOUND THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'end',
            CASE WHEN v_s.on_map THEN 'The journey ends. ' || public.rpg_map_time_text(v_s.clock) || '.'
                 WHEN v_s.round = 0 THEN 'The fight is over.'
                 ELSE 'The fight is over after ' || v_s.round || CASE WHEN v_s.round = 1 THEN ' round.' ELSE ' rounds.' END END);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_remove(p_participant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master takes someone out of a fight. If it was their turn, the turn passes on first.
DECLARE v_p record; v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master removes someone'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.current_participant_id = p_participant_id AND v_s.status = 'active' THEN
    PERFORM public.rpg_session_next_turn(v_p.session_id);
  END IF;
  DELETE FROM public.rpg_session_participants WHERE id = p_participant_id;
  UPDATE public.rpg_sessions SET current_participant_id = NULL
   WHERE id = v_p.session_id AND current_participant_id = p_participant_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
  SELECT v_p.agency_id, v_p.session_id, s.round, 'leave', v_p.name || CASE WHEN s.on_map THEN ' leaves the journey.' ELSE ' leaves the fight.' END
    FROM public.rpg_sessions s WHERE s.id = v_p.session_id;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_p.session_id;
END;
$function$;

INSERT INTO public.rpg_rules (agency_id, key, title, body, source, sort_order, section)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'world_map', 'The World Map and Walking',
'The world map is made of the same squares a fight is played on, each 3 feet 8 inches across, and the world is the size of the Earth: 24,901 miles around. The game master zooms from the whole world down to a battle grid 44 feet across, and on every grid a piece walks by the same rule as on a fight board.

On a journey everyone takes turns on one clock, the same clock a fight uses. A tick is a sixth of a second, so an hour is 21,600 ticks.

On its turn a piece walks straight toward any square the game master picks, the whole way in one go. Every square it steps into costs 1 plus its movement penalty, 5 ticks a point at Speed 10, faster or slower by Speed like everything else. Open land has penalty 0, forest 1, hills 1 and mountains 2.
*A mile is 1,439 squares. At Speed 10 a mile of open land is 1,439 x 5 = 7,195 ticks, 20 minutes: about 3 miles an hour. Zaboo (Speed 5) takes 7,195 x 20 / 15 = 9,593 ticks, 26 minutes 39 seconds. Mountains cost 3 a square, so a mile of them takes 1 hour at Speed 10.*

Nobody walks into the sea. A walk that reaches the water stops on the last dry square. A walk also stops one square short of anyone standing in its way.

A piece walks at most 8 hours a day, then camps 16 hours where it stands. If the day runs out on the way, it camps there and can carry on next turn. A piece can also camp on its turn instead of walking, which starts its walking day fresh.
*At Speed 10, 8 hours of open land is 24 miles.*',
       r.source, 48, r.section
  FROM public.rpg_rules r WHERE r.key = 'moving'
   AND NOT EXISTS (SELECT 1 FROM public.rpg_rules w WHERE w.key = 'world_map');

