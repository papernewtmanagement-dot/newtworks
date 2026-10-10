-- Roleplaying speed step 3 (Peter 2026-10-09): save the map ahead in the background, every hour.
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
       CROSS JOIN LATERAL (VALUES ('4-' || floor((p.pos_x - 1) / 20736.0)::bigint || '-' || floor((p.pos_y - 1) / 20736.0)::bigint),
                                  ('5-' || floor((p.pos_x - 1) / 1728.0)::bigint || '-' || floor((p.pos_y - 1) / 1728.0)::bigint),
                                  ('6-' || floor((p.pos_x - 1) / 144.0)::bigint || '-' || floor((p.pos_y - 1) / 144.0)::bigint)) AS v(view)
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
END $function$;
REVOKE ALL ON FUNCTION public.rpg_map_warm_run(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_warm_run(text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.dispatch_rpg_map_warm(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The hourly recipe Roleplaying map save-ahead (speed step 3, 2026-10-09): sends three background calls of
-- rpg_map_warm_run through the service login and returns at once: two batches of 45 Country grids next to big water
-- (until all are saved; about 90 seconds each) and the maps under the pieces of the open journey (up to 12).
DECLARE v_key text; v_left integer;
BEGIN
  SELECT s.setting_value INTO v_key FROM public.settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = 'supabase_service_role_key';
  IF v_key IS NULL THEN RETURN jsonb_build_object('ok', false, 'why', 'no service key'); END IF;
  PERFORM net.http_post(
    url := 'https://vulhdujhbwvibbojiimi.supabase.co/rest/v1/rpc/rpg_map_warm_run',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
    body := q.b, timeout_milliseconds := 240000)
    FROM (VALUES (jsonb_build_object('p_kind', 'water', 'p_limit', 45)), (jsonb_build_object('p_kind', 'water', 'p_limit', 45)),
                 (jsonb_build_object('p_kind', 'party', 'p_limit', 12))) AS q(b);
  RETURN jsonb_build_object('ok', true, 'records_processed', 3);
END $function$;
REVOKE ALL ON FUNCTION public.dispatch_rpg_map_warm(uuid, uuid) FROM PUBLIC, anon, authenticated;

INSERT INTO public.automation_recipes (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, composio_action, internal_handler, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Roleplaying map save-ahead',
       'Speed step 3 (2026-10-09): every hour, saves Country grids next to big water and the maps under the journey pieces in the background (dispatch_rpg_map_warm).',
       'cron', '0 * * * *', 'INTERNAL', 'dispatch_rpg_map_warm', true
 WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes r WHERE r.internal_handler = 'dispatch_rpg_map_warm');

