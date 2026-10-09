-- Roleplaying weather step 1: local weather rolled from the place and the journey clock, never stored.
CREATE OR REPLACE FUNCTION public.rpg_map_weather_table()
 RETURNS TABLE(climate text, kind text, name text, unsettled boolean, weight integer)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The one list of weather (weather step 1, 2026-10-09): for each kind of climate, the share of three-hour spells in
-- 100 that each weather takes, and whether a stormy or a fair stretch of days changes it (unsettled: rain, snow,
-- storms, dust; rpg_map_weather_at doubles or halves those). Claude estimates, after the share of hours with rain or
-- snow over land on Earth (Dai 2001, J. Climate 14: about 1 hour in 10 in wet mild lands, 1 in 100 in deserts) and
-- thunderstorm days (more in the hot wet lands): mild land rains 13 spells in 100 and storms 4; a desert is clear 85.
-- Climates by the ground of the Country cell: mild (open land, plains, forest, hills, towns, roads, lakes), cold
-- (pine forest), hot_wet (jungle), dry (desert), tundra, ice (snow and ice), swamp, high (mountains), sea.
SELECT w.climate, w.kind, n.name, w.kind NOT IN ('clear', 'cloudy', 'fog'), w.weight
  FROM (VALUES ('mild', 'clear', 45), ('mild', 'cloudy', 33), ('mild', 'fog', 5), ('mild', 'rain', 13), ('mild', 'storm', 4),
               ('cold', 'clear', 40), ('cold', 'cloudy', 37), ('cold', 'fog', 5), ('cold', 'rain', 8), ('cold', 'snow', 8), ('cold', 'storm', 2),
               ('hot_wet', 'clear', 30), ('hot_wet', 'cloudy', 35), ('hot_wet', 'fog', 5), ('hot_wet', 'rain', 18), ('hot_wet', 'storm', 12),
               ('dry', 'clear', 85), ('dry', 'cloudy', 10), ('dry', 'rain', 1), ('dry', 'storm', 1), ('dry', 'dust', 3),
               ('tundra', 'clear', 40), ('tundra', 'cloudy', 40), ('tundra', 'fog', 6), ('tundra', 'rain', 2), ('tundra', 'snow', 10), ('tundra', 'blizzard', 2),
               ('ice', 'clear', 45), ('ice', 'cloudy', 30), ('ice', 'fog', 5), ('ice', 'snow', 12), ('ice', 'blizzard', 8),
               ('swamp', 'clear', 30), ('swamp', 'cloudy', 35), ('swamp', 'fog', 15), ('swamp', 'rain', 15), ('swamp', 'storm', 5),
               ('high', 'clear', 40), ('high', 'cloudy', 30), ('high', 'fog', 10), ('high', 'rain', 8), ('high', 'snow', 8), ('high', 'storm', 4),
               ('sea', 'clear', 40), ('sea', 'cloudy', 38), ('sea', 'fog', 7), ('sea', 'rain', 11), ('sea', 'storm', 4)) AS w(climate, kind, weight)
  JOIN (VALUES ('clear', 'Clear'), ('cloudy', 'Cloudy'), ('fog', 'Fog'), ('rain', 'Rain'), ('storm', 'Thunderstorm'),
               ('snow', 'Snow'), ('blizzard', 'Blizzard'), ('dust', 'Dust storm')) AS n(kind, name) ON n.kind = w.kind;
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
DECLARE
  v_tph numeric; v_start numeric; v_seed integer;
  v_hour numeric; v_spell bigint; v_front integer; v_mult numeric; v_total numeric; v_aim numeric; v_run numeric := 0;
  v_climate text; v_r record;
BEGIN
  SELECT max(s.value) FILTER (WHERE s.key = 'ticks_per_hour'), max(s.value) FILTER (WHERE s.key = 'journey_start_hour'),
         max(s.value) FILTER (WHERE s.key = 'map_seed')::integer
    INTO v_tph, v_start, v_seed
    FROM public.rpg_settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('ticks_per_hour', 'journey_start_hour', 'map_seed');
  v_climate := CASE p_ground WHEN 'sea' THEN 'sea' WHEN 'pine' THEN 'cold' WHEN 'jungle' THEN 'hot_wet' WHEN 'desert' THEN 'dry'
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
  FOR v_r IN SELECT t.kind, t.name, t.weight * CASE WHEN t.unsettled THEN v_mult ELSE 1 END AS w
               FROM public.rpg_map_weather_table() t WHERE t.climate = v_climate LOOP
    v_run := v_run + v_r.w;
    IF v_aim < v_run THEN
      RETURN jsonb_build_object('kind', v_r.kind, 'name', v_r.name,
                                'front', CASE WHEN v_front <= 50 THEN 'fair' WHEN v_front <= 80 THEN 'usual' ELSE 'stormy' END);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('kind', 'clear', 'name', 'Clear', 'front', 'usual');
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_weather_view(p_level integer, p_x0 integer, p_y0 integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The weather the Maps tab draws over one grid (weather step 1, 2026-10-09), at the clock of the open journey; null with
-- no journey open, and on the World and Continent grids (their cells are wider than any weather). p_x0, p_y0 = the
-- first cell of the grid, counted across the whole world at its level (the view origin). The Country grid gets the
-- weather of each of its cells (x, y from 1, as the view numbers them); a finer grid lies inside one Country cell and
-- gets the weather of that cell as here. The rule itself is rpg_map_weather_at.
DECLARE
  v_clock bigint; v_cx integer; v_cy integer; v_div bigint;
BEGIN
  PERFORM public.require_login('family');
  SELECT s.clock INTO v_clock FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended' ORDER BY s.created_at DESC LIMIT 1;
  IF NOT FOUND OR coalesce(p_level, 1) < 3 OR p_level > 7 THEN RETURN NULL; END IF;
  IF p_level = 3 THEN
    RETURN jsonb_build_object('time', public.rpg_map_time_text(v_clock),
      'cells', (SELECT coalesce(jsonb_agg(jsonb_build_object('x', k.x - p_x0 + 1, 'y', k.y - p_y0 + 1)
                                          || public.rpg_map_weather_at(k.x, k.y, k.kind, v_clock) ORDER BY k.y, k.x), '[]'::jsonb)
                  FROM public.rpg_map_kinds(3, p_x0, p_y0, 12, 12) k));
  END IF;
  v_div := (12 ^ (p_level - 3))::bigint;
  v_cx := floor(p_x0 / v_div::numeric)::integer;
  v_cy := floor(p_y0 / v_div::numeric)::integer;
  RETURN jsonb_build_object('time', public.rpg_map_time_text(v_clock),
    'here', (SELECT public.rpg_map_weather_at(v_cx, v_cy, k.kind, v_clock) FROM public.rpg_map_kinds(3, v_cx, v_cy, 1, 1) k));
END $function$;

REVOKE ALL ON FUNCTION public.rpg_map_weather_at(integer, integer, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_weather_view(integer, integer, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.rpg_map_weather_view(integer, integer, integer) FROM anon;

