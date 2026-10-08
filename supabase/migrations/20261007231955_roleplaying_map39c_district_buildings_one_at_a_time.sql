-- Roleplaying world map step 14e fix 2 (Peter 2026-10-07 23:18: another statement timeout in Neneborough): District
-- grid buildings are worked out one grid at a time in the background (an advisory lock), so several at once no longer
-- slow every other map read past 8 seconds. No drops, no new tables.

CREATE OR REPLACE FUNCTION public.rpg_map_district_buildings(p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_make boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
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
DECLARE
  v_cell integer;
  g record;
  v_notes jsonb;
  v_list jsonb;
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
  UPDATE public.rpg_map_cache m SET notes = (coalesce(m.notes, '{}'::jsonb) - 'houses_asked') || jsonb_build_object('houses', v_list)
   WHERE m.level = 6 AND m.gx = g.gx AND m.gy = g.gy;
  RETURN v_list;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_map_district_buildings(integer, integer, integer, integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_district_buildings(integer, integer, integer, integer, boolean) TO service_role;

