-- Peter 2026-10-03 23:07, 1A: drop rpg_map_ground_text(boolean, integer). Since step 6 (roleplaying_map9_percent_costs)
-- the words for a ground come from rpg_map_band_text, and nothing calls the old function.
DROP FUNCTION IF EXISTS public.rpg_map_ground_text(boolean, integer);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND pg_get_functiondef(p.oid) LIKE '%rpg_map_ground_text(%') THEN
    RAISE EXCEPTION 'something still calls rpg_map_ground_text';
  END IF;
END $$;

