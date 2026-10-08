-- Roleplaying world map step 14f3 cleanup (Peter 2026-10-08 17:28, decision 1A): the older stream lines are no longer read
-- by anything since map43 found streams and brooks downhill, so their two functions go.
DROP FUNCTION IF EXISTS public.rpg_map_river_field(integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.rpg_map_river_sides(double precision, double precision, double precision, double precision);
NOTIFY pgrst, 'reload schema';

