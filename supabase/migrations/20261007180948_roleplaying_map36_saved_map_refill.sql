-- Step 14d2 (Peter 2026-10-07 18:06: the World map gave 'canceling statement due to statement timeout'). After the
-- saved map is cleared, the first World map had to save the World and Continent grids (about 9 s) inside the 8 s a login
-- may run. Now clearing the saved map sends two background calls that save them again at once (rpg_map_cache_warm).
-- No drops, no new tables, no settings; the saved map itself is left as it is.

CREATE OR REPLACE FUNCTION public.rpg_map_cache_warm(p_level integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Saves every grid of the World grid (1) or the Continent grid (2) not saved yet (step 14d2, 2026-10-07): the whole
-- level through rpg_map_cache_fill, the one home of saving a grid. Called in the background right after the saved map is
-- cleared (rpg_map_cache_clear), so the World map is never the one to pay for saving them: that takes about 9 seconds,
-- past the 8 a login may run a read, and the World map then failed with a timeout. Finer levels are saved as they are
-- opened, as before (one grid at a time is quick). Returns how many grids it saved; nothing for any other level.
BEGIN
  IF p_level NOT IN (1, 2) THEN
    RETURN 0;
  END IF;
  RETURN (SELECT public.rpg_map_cache_fill(p_level, 0, 0, l.across::integer, l.down::integer) FROM public.rpg_map_ladder() l WHERE l.level = p_level);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpg_map_cache_warm(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_cache_warm(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_cache_clear()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Forgets the whole saved map (step 13; Peter 2026-10-06: a function so map changes update the stored layers): every
-- grid is worked out again the next time it is opened. Called when a setting or a place card changes
-- (rpg_map_cache_watch), and by any migration that changes how the ground of a cell is worked out. Returns how many
-- grids it forgot.
-- (Step 14d2) The World and Continent grids are then saved again at once in the background (rpg_map_cache_warm, two
-- calls sent when this change is committed, run as the service login), so the next World map does not have to save
-- them inside its own 8-second limit.
DECLARE v_n integer; v_key text;
BEGIN
  DELETE FROM public.rpg_map_cache;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  SELECT s.setting_value INTO v_key FROM public.settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = 'supabase_service_role_key';
  IF v_key IS NOT NULL THEN
    PERFORM net.http_post(
      url := 'https://vulhdujhbwvibbojiimi.supabase.co/rest/v1/rpc/rpg_map_cache_warm',
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('p_level', q.lv),
      timeout_milliseconds := 120000)
      FROM (VALUES (1), (2)) AS q(lv);
  END IF;
  RETURN v_n;
END;
$function$;

