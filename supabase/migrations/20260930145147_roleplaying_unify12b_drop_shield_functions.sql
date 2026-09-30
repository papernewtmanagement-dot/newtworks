-- roleplaying_unify12b_drop_shield_functions
-- Peter 2026-09-30 "1A": rpg_shield_state and rpg_shield_wear were only ever the Shield-of-Faith case of
-- rpg_armor_state / rpg_armor_wear (unify12a) and nothing calls them now. Dropped; the re-check refuses if a caller remains.
DO $do$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_callers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname NOT IN ('rpg_shield_state', 'rpg_shield_wear')
     AND (pg_get_functiondef(p.oid) LIKE '%rpg_shield_state(%' OR pg_get_functiondef(p.oid) LIKE '%rpg_shield_wear(%');
  IF v_callers IS NOT NULL THEN RAISE EXCEPTION 'rpg_shield_state / rpg_shield_wear still called by: %', v_callers; END IF;
END $do$;
DROP FUNCTION IF EXISTS public.rpg_shield_wear(uuid, integer);
DROP FUNCTION IF EXISTS public.rpg_shield_state(uuid);

