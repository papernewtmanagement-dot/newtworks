-- Roleplaying weather: shown with no journey open, at the start of Day 1 (Peter 2026-10-09 1A).
CREATE OR REPLACE FUNCTION public.rpg_map_weather_view(p_level integer, p_x0 integer, p_y0 integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The weather the Maps tab draws over one grid (weather step 1, 2026-10-09), at the clock of the open journey, or with
-- no journey open at the start of Day 1 (clock 0, Peter 2026-10-09 1A); null on the World and Continent grids (their
-- cells are wider than any weather). p_x0, p_y0 = the
-- first cell of the grid, counted across the whole world at its level (the view origin). The Country grid gets the
-- weather of each of its cells (x, y from 1, as the view numbers them; rpg_map_weather_at); a finer grid lies inside one
-- Country cell and gets the weather at its first square as here (rpg_map_weather_here).
DECLARE
  v_clock bigint; v_cell bigint;
BEGIN
  PERFORM public.require_login('family');
  SELECT s.clock INTO v_clock FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended' ORDER BY s.created_at DESC LIMIT 1;
  v_clock := coalesce(v_clock, 0);
  IF coalesce(p_level, 1) < 3 OR p_level > 7 THEN RETURN NULL; END IF;
  IF p_level = 3 THEN
    RETURN jsonb_build_object('time', public.rpg_map_time_text(v_clock),
      'cells', (SELECT coalesce(jsonb_agg(jsonb_build_object('x', k.x - p_x0 + 1, 'y', k.y - p_y0 + 1)
                                          || public.rpg_map_weather_at(k.x, k.y, k.kind, v_clock) ORDER BY k.y, k.x), '[]'::jsonb)
                  FROM public.rpg_map_kinds(3, p_x0, p_y0, 12, 12) k));
  END IF;
  SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  RETURN jsonb_build_object('time', public.rpg_map_time_text(v_clock),
    'here', public.rpg_map_weather_here(p_x0::bigint * v_cell, p_y0::bigint * v_cell, v_clock));
END $function$;

