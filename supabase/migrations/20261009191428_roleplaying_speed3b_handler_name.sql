-- The runner reads a handler named dispatch_<x> as an edge function <x>: the save-ahead handler is renamed so the runner calls it in SQL.
ALTER FUNCTION public.dispatch_rpg_map_warm(uuid, uuid) RENAME TO rpg_map_warm_send;
COMMENT ON FUNCTION public.rpg_map_warm_send(uuid, uuid) IS 'Hourly recipe Roleplaying map save-ahead (speed step 3): sends the background calls of rpg_map_warm_run. Not named dispatch_*: the runner reads those as edge functions.';
UPDATE public.automation_recipes SET internal_handler = 'rpg_map_warm_send', updated_at = now() WHERE internal_handler = 'dispatch_rpg_map_warm';

