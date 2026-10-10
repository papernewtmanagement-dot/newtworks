-- Save-ahead: one water batch of 120 an hour (two at once fought over the same grids).
CREATE OR REPLACE FUNCTION public.rpg_map_warm_send(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The hourly recipe Roleplaying map save-ahead (speed step 3, 2026-10-09): sends three background calls of
-- rpg_map_warm_run through the service login and returns at once: one batch of 120 Country grids next to big water
-- (until all are saved; about 2 minutes; two batches at once fought over the same grids and one failed on a lock) and
-- the maps under the pieces of the open journey (up to 12).
DECLARE v_key text; v_left integer;
BEGIN
  SELECT s.setting_value INTO v_key FROM public.settings s
   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = 'supabase_service_role_key';
  IF v_key IS NULL THEN RETURN jsonb_build_object('ok', false, 'why', 'no service key'); END IF;
  PERFORM net.http_post(
    url := 'https://vulhdujhbwvibbojiimi.supabase.co/rest/v1/rpc/rpg_map_warm_run',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
    body := q.b, timeout_milliseconds := 240000)
    FROM (VALUES (jsonb_build_object('p_kind', 'water', 'p_limit', 120)),
                 (jsonb_build_object('p_kind', 'party', 'p_limit', 12))) AS q(b);
  RETURN jsonb_build_object('ok', true, 'records_processed', 2);
END $function$;

